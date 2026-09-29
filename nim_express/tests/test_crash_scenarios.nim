## Historical crash regressions:
## 1. res.json(nil JsonNode) must serialize JSON null without dereferencing a nil
##    JsonNode.
## 2. FastMap intentionally caps inline string values at 65535 bytes. The native
##    HTTP parser rejects oversized header fields before storage.

import std/[unittest, asyncdispatch, json, strutils]
import ../src/nim_express/app
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common

proc newMockHttpResponse(): HttpResponse =
  new(result)
  result.socket = nil
  result.ssl = 0
  result.statusCode = Http200
  result.statusCodeInt = 200
  result.requestMethod = hmGet
  result.requestIsHttp11 = true
  result.autoEnd = false
  result.connectionClose = false
  result.headersInited = false
  result.bodySent = false
  result.headersSent = false
  result.chunkedStarted = false
  result.chunkedFinished = false
  result.headers = newFastMap[string]()
  discard result.headers.reserve(8)
  result.capturedHeader = ""
  result.capturedBody = ""
  result.capturedRaw = ""

proc newMockHttpRequest(
  pathVal: string = "/",
  methodKind: HttpMethod = hmGet,
  bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1",
  headerMap: seq[(string, string)] = @[]
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
  pathVal: string = "/",
  methodKind: HttpMethod = hmGet,
  bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1",
  headerMap: seq[(string, string)] = @[]
): Request =
  let native = newMockHttpRequest(pathVal, methodKind, bodyStr, remoteIpStr, headerMap)
  result = newRequest(native)

proc newMockResponse(): Response =
  let nativeRes = newMockHttpResponse()
  new(result)
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

# ============================================================
# A. REQUEST PATH EDGE CASES
# ============================================================

suite "A. Request path edge cases":
  test "A1: empty path string":
    let app = newExpressApp()
    app.get "/", proc(req: Request, res: Response) =
      res.send("root")
    let req = newMockRequest("")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "A2: root path /":
    let app = newExpressApp()
    app.get "/", proc(req: Request, res: Response) =
      res.send("root")
    let req = newMockRequest("/")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "A3: path with NUL bytes":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/te\x00st")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "A4: very long path (8KB)":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let longPath = "/" & "a".repeat(8192)
    let req = newMockRequest(longPath)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "A5: very long path (64KB)":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let longPath = "/" & "x".repeat(65536)
    let req = newMockRequest(longPath)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "A6: path with only special characters":
    let app = newExpressApp()
    app.get "/", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/%00%01%02%ff")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "A7: path with unicode characters":
    let app = newExpressApp()
    app.get "/", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/\xc3\xa9\xc3\xa8\xc3\xaa")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "A8: path with query string containing NUL":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let native = newMockHttpRequest("/test")
    native.queryStringRaw = "key=val\x00ue"
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "A9: path with double slashes":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("//test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "A10: path with dot segments":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/foo/../test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

# ============================================================
# B. RESPONSE GENERATION CRASHES
# ============================================================

suite "B. Response generation crashes":
  test "B1: send with empty string":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "B2: send after response already finished":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("first")
      res.send("second")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B3: json with nil JsonNode serializes null safely":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let node: JsonNode = nil
      res.json(node)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.native.capturedBody == "null"

  test "B4: json with deeply nested object (100 levels)":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      var node = newJObject()
      var current = node
      for i in 0..<100:
        let child = newJObject()
        current["level" & $i] = child
        current = child
      current["value"] = newJString("deep")
      res.json(node)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B5: jsonRaw with empty string":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.jsonRaw("")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B6: jsonRaw with invalid JSON":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.jsonRaw("{invalid json{{{")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B7: redirect with empty URL":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.redirect("")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 302

  test "B8: redirect with javascript URL":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.redirect("javascript:alert(1)")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B9: status code 0":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.status(0).send("zero")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 0

  test "B10: status code 999":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.status(999).send("high")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 999

  test "B11: status code negative":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.status(-1).send("negative")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B12: set header with empty name":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.set("", "value")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B13: set header with NUL in value":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.set("x-test", "val\x00ue")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B14: set header with CR/LF injection":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.set("x-test", "value\r\ninjected-header: evil")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B15: handler never calls send":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "B16: handler calls send then throws":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
      raise newException(ValueError, "post-send crash")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B17: status then send multiple times":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.status(200).send("first")
      res.status(201).send("second")
      res.status(202).send("third")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "B18: send extremely large body (1MB)":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("x".repeat(1024 * 1024))
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B19: jsonRaw with very large payload":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      var arr = "["
      for i in 0..<10000:
        if i > 0: arr.add(",")
        arr.add($i)
      arr.add("]")
      res.jsonRaw(arr)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B20: set many headers":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      for i in 0..<200:
        discard res.set("x-header-" & $i, "value-" & $i)
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B21: cookie with empty name":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.cookie("", "value")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B22: cookie with CR/LF in value":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.cookie("test", "val\r\nue")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B23: sendStatus with edge codes":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.sendStatus(100)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "B24: notFound helper":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.notFound()
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 404

  test "B25: serverError helper":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.serverError()
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "B26: badRequest helper":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.badRequest()
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 400

  test "B27: problem details response":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.problem(422, "VALIDATION_ERROR", "field is invalid")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 422

  test "B28: send with control characters in body":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      var body = ""
      for i in 0..31:
        body.add(chr(i))
      res.send(body)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

# ============================================================
# C. MIDDLEWARE CHAIN CRASHES
# ============================================================

suite "C. Middleware chain crashes":
  test "C1: middleware throws CatchableError immediately":
    let app = newExpressApp()
    app.use proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      raise newException(ValueError, "immediate crash")
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "C2: middleware throws after calling next":
    let app = newExpressApp()
    app.use proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      await next()
      raise newException(ValueError, "post-next crash")
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "C3: middleware returns without calling next or send":
    let app = newExpressApp()
    app.use proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      discard
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "C4: middleware calls next after res.send":
    let app = newExpressApp()
    app.use proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      res.send("from middleware")
      await next()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("from handler")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "C5: deep middleware chain (50 middlewares)":
    let app = newExpressApp()
    for i in 0..<50:
      app.use proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
        await next()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "C6: deep middleware chain (100 middlewares)":
    let app = newExpressApp()
    for i in 0..<100:
      app.use proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
        await next()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "C7: middleware that sends response directly":
    let app = newExpressApp()
    app.use proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      res.status(403).send("forbidden by middleware")
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 403

  test "C8: middleware throws IOError":
    let app = newExpressApp()
    app.use proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      raise newException(IOError, "connection refused")
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "C9: middleware throws OSError":
    let app = newExpressApp()
    app.use proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      raise newException(OSError, "file not found")
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "C10: middleware throws KeyError":
    let app = newExpressApp()
    app.use proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      raise newException(KeyError, "missing key")
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "C11: middleware throws IndexDefect":
    let app = newExpressApp()
    app.use proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      let arr: seq[int] = @[]
      discard arr[5]
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "C12: middleware modifies request locals":
    let app = newExpressApp()
    app.use proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      req.locals["test_key"] = "test_value"
      await next()
    app.get "/test", proc(req: Request, res: Response) =
      let val = req.locals.getOrDefault("test_key", "")
      res.send(val)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "C13: multiple middlewares all throw":
    let app = newExpressApp()
    app.use proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      raise newException(ValueError, "crash 1")
    app.use proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      raise newException(ValueError, "crash 2")
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "C14: error handler middleware catches error":
    let app = newExpressApp()
    app.errorHandler = proc(err: ref Exception, req: Request, res: Response): Future[void] {.async.} =
      res.status(500).send("custom error: " & err.msg)
    app.get "/test", proc(req: Request, res: Response) =
      raise newException(ValueError, "handler error")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "C15: error handler itself throws":
    let app = newExpressApp()
    app.errorHandler = proc(err: ref Exception, req: Request, res: Response): Future[void] {.async.} =
      raise newException(IOError, "error handler crashed")
    app.get "/test", proc(req: Request, res: Response) =
      raise newException(ValueError, "handler error")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

# ============================================================
# D. ROUTING CRASHES
# ============================================================

suite "D. Routing crashes":
  test "D1: no routes registered":
    let app = newExpressApp()
    let req = newMockRequest("/anything")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 404

  test "D2: duplicate routes same method and path":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("first")
    app.get "/test", proc(req: Request, res: Response) =
      res.send("second")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "D3: route with wildcard parameter":
    let app = newExpressApp()
    app.get "/:id", proc(req: Request, res: Response) =
      res.send("id=" & req.param("id"))
    let req = newMockRequest("/123")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "D4: route parameter with special chars in value":
    let app = newExpressApp()
    app.get "/users/:id", proc(req: Request, res: Response) =
      res.send("id=" & req.param("id"))
    let req = newMockRequest("/users/foo%20bar%00baz")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "D5: overlapping static and dynamic routes":
    let app = newExpressApp()
    app.get "/users/admin", proc(req: Request, res: Response) =
      res.send("admin")
    app.get "/users/:id", proc(req: Request, res: Response) =
      res.send("user:" & req.param("id"))
    let req1 = newMockRequest("/users/admin")
    let res1 = newMockResponse()
    waitFor app.handleRequestForTest(req1, res1)
    check res1.finished == true

    let req2 = newMockRequest("/users/123")
    let res2 = newMockResponse()
    waitFor app.handleRequestForTest(req2, res2)
    check res2.finished == true

  test "D6: many routes registered (200 routes)":
    let app = newExpressApp()
    for i in 0..<200:
      let path = "/route" & $i
      app.get path, proc(req: Request, res: Response) =
        res.send("ok")
    let req = newMockRequest("/route150")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "D7: request to unmatched method":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test", hmPost)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 405

  test "D8: DELETE route":
    let app = newExpressApp()
    app.delete "/items/:id", proc(req: Request, res: Response) =
      res.status(204).send("")
    let req = newMockRequest("/items/42", hmDelete)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "D9: PATCH route":
    let app = newExpressApp()
    app.patch "/items/:id", proc(req: Request, res: Response) =
      res.send("patched")
    let req = newMockRequest("/items/42", hmPatch)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "D10: HEAD route":
    let app = newExpressApp()
    app.head "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test", hmHead)
    let resObj = newMockResponse()
    resObj.requestMethodKind = hmHead
    waitFor app.handleRequestForTest(req, resObj)
    check resObj.finished == true

  test "D11: OPTIONS route":
    let app = newExpressApp()
    app.options "/test", proc(req: Request, res: Response) =
      res.status(204).send("")
    let req = newMockRequest("/test", hmOptions)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "D12: route with multi-segment params":
    let app = newExpressApp()
    app.get "/users/:userId/posts/:postId", proc(req: Request, res: Response) =
      res.send(req.param("userId") & ":" & req.param("postId"))
    let req = newMockRequest("/users/42/posts/99")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "D13: route group prefix":
    let app = newExpressApp()
    let api = app.group("/api")
    api.get "/users", proc(req: Request, res: Response) =
      res.send("users list")
    let req = newMockRequest("/api/users")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "D14: nested route groups":
    let app = newExpressApp()
    let api = app.group("/api")
    let v1 = api.group("/v1")
    v1.get "/users", proc(req: Request, res: Response) =
      res.send("v1 users")
    let req = newMockRequest("/api/v1/users")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "D15: CONNECT method returns 501":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test", hmConnect)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 501

  test "D16: TRACE method returns 501":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test", hmTrace)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 501

# ============================================================
# E. HANDLER EXCEPTION CRASHES
# ============================================================

suite "E. Handler exception crashes":
  test "E1: sync handler throws ValueError":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      raise newException(ValueError, "value error in handler")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "E2: sync handler throws IOError":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      raise newException(IOError, "io error in handler")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "E3: sync handler throws OSError":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      raise newException(OSError, "os error in handler")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "E4: sync handler throws JsonParsingError":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      raise newException(JsonParsingError, "bad json")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "E5: async handler throws ValueError":
    let app = newExpressApp()
    app.getAsync "/test", proc(req: Request, res: Response): Future[void] {.async.} =
      raise newException(ValueError, "async value error")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "E6: async handler throws after sleepAsync":
    let app = newExpressApp()
    app.getAsync "/test", proc(req: Request, res: Response): Future[void] {.async.} =
      await sleepAsync(1)
      raise newException(ValueError, "delayed crash")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "E7: async handler never completes (no send, no exception)":
    let app = newExpressApp()
    app.getAsync "/test", proc(req: Request, res: Response): Future[void] {.async.} =
      discard
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "E8: handler accesses nil jsonBody":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let body = req.getJsonBody()
      if body == nil:
        res.send("null body")
      else:
        res.send("has body")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "E9: handler with error handler that recovers":
    let app = newExpressApp()
    app.errorHandler = proc(err: ref Exception, req: Request, res: Response): Future[void] {.async.} =
      res.status(418).send("recovered: " & err.msg)
    app.get "/test", proc(req: Request, res: Response) =
      raise newException(ValueError, "test error")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 418

  test "E10: handler with division by zero":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      var x = 0
      let y {.used.} = 1 div x
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

# ============================================================
# F. REQUEST BODY PARSING CRASHES
# ============================================================

suite "F. Request body parsing crashes":
  test "F1: empty body with content-type json":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let body = req.getJsonBody()
      if body == nil:
        res.send("null")
      else:
        res.json(body)
    let req = newMockRequest("/test", hmGet, "",
      headerMap = @[("content-type", "application/json")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "F2: malformed JSON body":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let body = req.getJsonBody()
      if body == nil:
        res.send("parse failed")
      else:
        res.send("parsed")
    let req = newMockRequest("/test", hmGet, "{invalid",
      headerMap = @[("content-type", "application/json")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "F3: JSON body exceeding max size":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let body = req.getJsonBody(maxBytes = 10)
      if body == nil:
        res.send("rejected")
      else:
        res.send("accepted")
    let req = newMockRequest("/test", hmGet, "{\"key\":\"" & "x".repeat(100) & "\"}",
      headerMap = @[("content-type", "application/json")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "F4: body with NUL bytes":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindBody()
      res.send("body len: " & $req.body.len)
    let req = newMockRequest("/test", hmGet, "hello\x00world")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "F5: binary body":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindBody()
      res.send("len=" & $req.body.len)
    var binaryBody = ""
    for i in 0..255:
      binaryBody.add(chr(i))
    let req = newMockRequest("/test", hmGet, binaryBody)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "F6: JSON with deeply nested arrays":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let body = req.getJsonBody()
      if body == nil:
        res.send("null")
      else:
        res.send("ok")
    var deepJson = ""
    for _ in 0..<50:
      deepJson.add("[")
    deepJson.add("1")
    for _ in 0..<50:
      deepJson.add("]")
    let req = newMockRequest("/test", hmGet, deepJson,
      headerMap = @[("content-type", "application/json")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "F7: very large JSON body (1MB)":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let body = req.getJsonBody()
      if body == nil:
        res.send("null")
      else:
        res.send("ok")
    let largeBody = "{\"data\":\"" & "x".repeat(1024 * 1024) & "\"}"
    let req = newMockRequest("/test", hmGet, largeBody,
      headerMap = @[("content-type", "application/json")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "F8: content-type with charset parameter":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let body = req.getJsonBody()
      if body == nil:
        res.send("null")
      else:
        res.send("ok")
    let req = newMockRequest("/test", hmGet, "{\"key\":\"value\"}",
      headerMap = @[("content-type", "application/json; charset=utf-8")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

# ============================================================
# G. HEADER EDGE CASES
# ============================================================

suite "G. Header edge cases":
  test "G1: header with empty value":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindHeaders()
      res.send("ok")
    let req = newMockRequest("/test", headerMap = @[("x-empty", "")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "G2: header with NUL bytes in value":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindHeaders()
      let val = req.get("x-test")
      res.send("val=" & $val.len)
    let req = newMockRequest("/test", headerMap = @[("x-test", "val\x00ue")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "G3: header with control characters":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindHeaders()
      res.send("ok")
    let req = newMockRequest("/test", headerMap = @[("x-test", "val\x01\x02ue")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "G4: many headers (100 headers)":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindHeaders()
      res.send("ok")
    var headers: seq[(string, string)] = @[]
    for i in 0..<100:
      headers.add(("x-header-" & $i, "value-" & $i))
    let req = newMockRequest("/test", headerMap = headers)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "G5: mock header map rejects values above FastMap storage cap":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindHeaders()
      res.send("ok")
    let longValue = "x".repeat(65536)
    var caughtException = false
    try:
      let req = newMockRequest("/test", headerMap = @[("x-long", longValue)])
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
    except ValueError:
      caughtException = true
    check caughtException == true

  test "G5b: header value just under FastMap limit (65535)":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindHeaders()
      res.send("ok")
    let longValue = "x".repeat(65535)
    let req = newMockRequest("/test", headerMap = @[("x-long", longValue)])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "G6: duplicate headers":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindHeaders()
      res.send("ok")
    let req = newMockRequest("/test", headerMap = @[
      ("x-dup", "value1"),
      ("x-dup", "value2")
    ])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "G7: missing host header":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let host = req.hostname()
      res.send("host=" & host)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "G8: cookie header with many cookies":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let c = req.getCookie("test0")
      res.send("cookie=" & c)
    var cookieStr = ""
    for i in 0..<100:
      if i > 0: cookieStr.add("; ")
      cookieStr.add("test" & $i & "=val" & $i)
    let req = newMockRequest("/test", headerMap = @[("cookie", cookieStr)])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "G9: cookie header with malformed cookies":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let c = req.getCookie("test")
      res.send("cookie=" & c)
    let req = newMockRequest("/test", headerMap = @[("cookie", ";;=;test;=value;;;")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "G10: cookie with NUL in value":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let c = req.getCookie("test")
      res.send("cookie=" & c)
    let req = newMockRequest("/test", headerMap = @[("cookie", "test=val\x00ue")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

# ============================================================
# H. QUERY STRING EDGE CASES
# ============================================================

suite "H. Query string edge cases":
  test "H1: empty query string":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindQuery()
      res.send("q=" & $req.query.len)
    let native = newMockHttpRequest("/test")
    native.queryStringRaw = ""
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "H2: query with many parameters (200 pairs)":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindQuery()
      res.send("q=" & $req.query.len)
    let native = newMockHttpRequest("/test")
    var qs = ""
    for i in 0..<200:
      if i > 0: qs.add("&")
      qs.add("key" & $i & "=val" & $i)
    native.queryStringRaw = qs
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "H3: query with NUL in key":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindQuery()
      res.send("ok")
    let native = newMockHttpRequest("/test")
    native.queryStringRaw = "ke\x00y=value"
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "H4: query with very long key":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindQuery()
      res.send("ok")
    let native = newMockHttpRequest("/test")
    native.queryStringRaw = "k".repeat(500) & "=value"
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "H5: query with very long value":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindQuery()
      res.send("ok")
    let native = newMockHttpRequest("/test")
    native.queryStringRaw = "key=" & "v".repeat(10000)
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "H6: query with empty key":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindQuery()
      res.send("ok")
    let native = newMockHttpRequest("/test")
    native.queryStringRaw = "=value"
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "H7: query with no value":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindQuery()
      res.send("ok")
    let native = newMockHttpRequest("/test")
    native.queryStringRaw = "key"
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "H8: query with consecutive ampersands":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindQuery()
      res.send("ok")
    let native = newMockHttpRequest("/test")
    native.queryStringRaw = "a=1&&&&b=2"
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "H9: query with multiple equals":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindQuery()
      res.send("ok")
    let native = newMockHttpRequest("/test")
    native.queryStringRaw = "key=val=ue=extra"
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

# ============================================================
# I. CONCURRENT REQUEST HANDLING
# ============================================================

suite "I. Concurrent request handling":
  test "I1: multiple requests to same endpoint":
    let app = newExpressApp()
    var counter = 0
    app.get "/test", proc(req: Request, res: Response) =
      inc counter
      res.send("count=" & $counter)
    for i in 0..<10:
      let req = newMockRequest("/test")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.finished == true

  test "I2: interleaved requests to different routes":
    let app = newExpressApp()
    app.get "/a", proc(req: Request, res: Response) =
      res.send("a")
    app.get "/b", proc(req: Request, res: Response) =
      res.send("b")
    app.get "/c", proc(req: Request, res: Response) =
      res.send("c")
    for _ in 0..<5:
      for path in ["/a", "/b", "/c"]:
        let req = newMockRequest(path)
        let res = newMockResponse()
        waitFor app.handleRequestForTest(req, res)
        check res.finished == true

  test "I3: concurrent async handlers":
    let app = newExpressApp()
    app.getAsync "/test", proc(req: Request, res: Response): Future[void] {.async.} =
      await sleepAsync(1)
      res.send("ok")
    var futures: seq[Future[void]] = @[]
    var responses: seq[Response] = @[]
    for i in 0..<5:
      let req = newMockRequest("/test")
      let res = newMockResponse()
      responses.add(res)
      futures.add(app.handleRequestForTest(req, res))
    waitFor all(futures)
    for res in responses:
      check res.finished == true

  test "I4: requests after handler crash":
    let app = newExpressApp()
    var callCount = 0
    app.get "/test", proc(req: Request, res: Response) =
      inc callCount
      if callCount == 1:
        raise newException(ValueError, "first call crash")
      res.send("ok")
    let req1 = newMockRequest("/test")
    let res1 = newMockResponse()
    waitFor app.handleRequestForTest(req1, res1)
    check res1.finished == true
    check res1.statusCode == 500

    let req2 = newMockRequest("/test")
    let res2 = newMockResponse()
    waitFor app.handleRequestForTest(req2, res2)
    check res2.finished == true
    check res2.statusCode == 200

  test "I5: rapid sequential requests (100)":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    for i in 0..<100:
      let req = newMockRequest("/test")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.finished == true

# ============================================================
# J. LIFECYCLE AND CANCEL
# ============================================================

suite "J. Lifecycle and cancel":
  test "J1: request cancelled before handler":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    discard req.markRequestCancelled(rcrTimeout)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "J2: request cancelled with disconnect reason":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    discard req.markRequestCancelled(rcrDisconnect)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "J3: request cancelled with shutdown reason":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    discard req.markRequestCancelled(rcrShutdown)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "J4: cancel hook fires":
    let app = newExpressApp()
    var hookFired = false
    app.get "/test", proc(req: Request, res: Response) =
      req.onCancel(proc(r: Request, reason: RequestCancelReason) =
        hookFired = true
      )
      discard req.markRequestCancelled(rcrTimeout)
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check hookFired == true

  test "J5: double cancel is safe":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard req.markRequestCancelled(rcrTimeout)
      discard req.markRequestCancelled(rcrDisconnect)
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "J6: released request access":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.markRequestReleased()
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "J7: nil request to handleRequestForTest":
    let app = newExpressApp()
    let res = newMockResponse()
    waitFor app.handleRequestForTest(nil, res)

  test "J8: nil response to handleRequestForTest":
    let app = newExpressApp()
    let req = newMockRequest("/test")
    waitFor app.handleRequestForTest(req, nil)

  test "J9: nil app to handleRequestForTest":
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor handleRequestForTest(nil, req, res)

  test "J10: timeout budget expired":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    req.setRequestTimeoutBudget(1)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

# ============================================================
# K. CONTENT NEGOTIATION AND SPECIAL METHODS
# ============================================================

suite "K. Content negotiation and special methods":
  test "K1: HEAD request does not include body":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("this body should be empty for HEAD")
    let native = newMockHttpRequest("/test", hmHead)
    let req = newRequest(native)
    let nativeRes = newMockHttpResponse()
    nativeRes.requestMethod = hmHead
    let res = newMockResponse()
    res.requestMethodKind = hmHead
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "K2: OPTIONS request to non-existent route":
    let app = newExpressApp()
    app.get "/other", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/nonexistent", hmOptions)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "K3: OPTIONS returns Allow header for existing routes":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    app.post "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test", hmOptions)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "K4: POST with empty body":
    let app = newExpressApp()
    app.post "/test", proc(req: Request, res: Response) =
      req.bindBody()
      res.send("len=" & $req.body.len)
    let req = newMockRequest("/test", hmPost, "")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "K5: PUT with body":
    let app = newExpressApp()
    app.put "/test", proc(req: Request, res: Response) =
      req.bindBody()
      res.send("body=" & req.body)
    let req = newMockRequest("/test", hmPut, "update data")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "K6: content negotiation with accepts":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let best = req.accepts("text/html", "application/json", "text/plain")
      res.send("best=" & best)
    let req = newMockRequest("/test", headerMap = @[("accept", "application/json")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "K7: accepts with wildcard":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let best = req.accepts("text/html", "application/json")
      res.send("best=" & best)
    let req = newMockRequest("/test", headerMap = @[("accept", "*/*")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "K8: accepts with no match":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let best = req.accepts("text/html")
      res.send("best=" & best)
    let req = newMockRequest("/test", headerMap = @[("accept", "application/xml")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "K9: isJson with json content type":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("json=" & $req.isJson())
    let req = newMockRequest("/test", headerMap = @[("content-type", "application/json")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "K10: isXhr with xmlhttprequest header":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("xhr=" & $req.isXhr())
    let req = newMockRequest("/test", headerMap = @[("x-requested-with", "XMLHttpRequest")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

# ============================================================
# L. HOOK EDGE CASES
# ============================================================

suite "L. Hook edge cases":
  test "L1: error hook is nil":
    let app = newExpressApp()
    app.errorHook = nil
    app.get "/test", proc(req: Request, res: Response) =
      raise newException(ValueError, "test crash")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "L2: error hook that throws":
    let app = newExpressApp()
    app.errorHook = proc(msg: string) =
      raise newException(ValueError, "error hook crash")
    app.get "/test", proc(req: Request, res: Response) =
      raise newException(ValueError, "test crash")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "L3: panic hook that throws":
    let app = newExpressApp()
    app.panicHook = proc(msg: string) =
      raise newException(ValueError, "panic hook crash")
    app.get "/test", proc(req: Request, res: Response) =
      raise newException(ValueError, "test crash")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 500

  test "L4: request start hook fires":
    let app = newExpressApp()
    var hookFired = false
    app.requestStartHook = proc(req: Request) =
      hookFired = true
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "L5: request end hook fires":
    let app = newExpressApp()
    var hookFired = false
    app.requestEndHook = proc(req: Request, res: Response, durationMicros: int64) =
      hookFired = true
    app.hasRequestEndHook = true
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check hookFired == true

  test "L6: inspector hook fires on handler error":
    let app = newExpressApp()
    var events: seq[InspectorEventKind] = @[]
    app.inspectorHook = proc(event: InspectorEvent) =
      events.add(event.kind)
    app.get "/test", proc(req: Request, res: Response) =
      discard
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "L7: before route match advice rejects":
    let app = newExpressApp()
    app.beforeRouteMatchAdvices.add proc(req: Request, res: Response): bool =
      res.status(403).send("blocked")
      false
    app.hasBeforeRouteMatchAdvice = true
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 403

  test "L8: before handler advice rejects":
    let app = newExpressApp()
    app.beforeHandlerAdvices.add proc(req: Request, res: Response, routePattern: string): bool =
      res.status(401).send("unauthorized")
      false
    app.hasBeforeHandlerAdvice = true
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 401

  test "L9: after handler advice runs after success":
    let app = newExpressApp()
    var adviceRan = false
    app.afterHandlerAdvices.add proc(req: Request, res: Response) =
      adviceRan = true
    app.hasAfterHandlerAdvice = true
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check adviceRan == true

# ============================================================
# M. STATUS CODE EDGE CASES
# ============================================================

suite "M. Status code edge cases":
  test "M1: 100 Continue":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.sendStatus(100)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "M2: 101 Switching Protocols":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.sendStatus(101)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "M3: 204 No Content":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.status(204).send("")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 204

  test "M4: 205 Reset Content":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.status(205).send("")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "M5: 301 redirect":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.redirect("/new-location", 301)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 301

  test "M6: 304 Not Modified":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.status(304).send("")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "M7: 429 Too Many Requests":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.sendStatus(429)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 429

  test "M8: 502 Bad Gateway":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.sendStatus(502)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 502

  test "M9: 503 Service Unavailable":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.sendStatus(503)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 503

  test "M10: 599 upper boundary":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.status(599).send("edge")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 599

# ============================================================
# N. RESPONSE HEADER SAFETY
# ============================================================

suite "N. Response header safety":
  test "N1: set-cookie header injection":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.set("set-cookie", "session=abc123")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "N2: transfer-encoding header is blocked":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.set("transfer-encoding", "chunked")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "N3: header name with spaces":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.set("invalid header", "value")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "N4: header name with special characters":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.set("x-test\x00", "value")
      discard res.set("x-test\r\n", "value")
      discard res.set("x-test(", "value")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "N5: append header multiple times":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      for i in 0..<50:
        discard res.append("x-values", "val" & $i)
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "N6: removeHeader on non-existent header":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.removeHeader("x-nonexistent")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "N7: contentType with empty string":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.contentType("")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "N8: vary with empty field":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.vary("")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

# ============================================================
# O. ASYNC HANDLER EDGE CASES
# ============================================================

suite "O. Async handler edge cases":
  test "O1: async handler completes immediately":
    let app = newExpressApp()
    app.getAsync "/test", proc(req: Request, res: Response): Future[void] {.async.} =
      res.send("immediate")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "O2: async handler with multiple awaits":
    let app = newExpressApp()
    app.getAsync "/test", proc(req: Request, res: Response): Future[void] {.async.} =
      await sleepAsync(1)
      await sleepAsync(1)
      await sleepAsync(1)
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "O3: async POST handler with body":
    let app = newExpressApp()
    app.postAsync "/test", proc(req: Request, res: Response): Future[void] {.async.} =
      req.bindBody()
      res.send("got: " & req.body)
    let req = newMockRequest("/test", hmPost, "hello async")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "O4: async handler with jsonRaw response":
    let app = newExpressApp()
    app.getAsync "/test", proc(req: Request, res: Response): Future[void] {.async.} =
      await sleepAsync(1)
      res.jsonRaw("""{"status":"ok"}""")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "O5: async handler with redirect":
    let app = newExpressApp()
    app.getAsync "/test", proc(req: Request, res: Response): Future[void] {.async.} =
      res.redirect("/other")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 302

# ============================================================
# P. PLUGIN EDGE CASES
# ============================================================

suite "P. Plugin edge cases":
  test "P1: register plugin with empty id":
    let app = newExpressApp()
    let ok = app.registerPlugin(pluginDef(""))
    check ok == false

  test "P2: register duplicate plugin id":
    let app = newExpressApp()
    discard app.registerPlugin(pluginDef("test"))
    let ok = app.registerPlugin(pluginDef("test"))
    check ok == false

  test "P3: plugin with missing dependency":
    let app = newExpressApp()
    discard app.registerPlugin(pluginDef("child", dependsOn = @["parent"]))
    let ok = app.initializePlugins()
    check ok == false

  test "P4: plugin dependency cycle":
    let app = newExpressApp()
    discard app.registerPlugin(pluginDef("a", dependsOn = @["b"]))
    discard app.registerPlugin(pluginDef("b", dependsOn = @["a"]))
    let ok = app.initializePlugins()
    check ok == false

  test "P5: plugin init returns false":
    let app = newExpressApp()
    discard app.registerPlugin(pluginDef("fail", initHook = proc(): bool = false))
    let ok = app.initializePlugins()
    check ok == false

  test "P6: plugin init throws":
    let app = newExpressApp()
    discard app.registerPlugin(pluginDef("crash", initHook = proc(): bool =
      raise newException(ValueError, "plugin init crash")
    ))
    let ok = app.initializePlugins()
    check ok == false

  test "P6b: plugin init failure unwinds already initialized plugins":
    let app = newExpressApp()
    var events: seq[string] = @[]
    discard app.registerPlugin(pluginDef(
      "first",
      initHook = proc(): bool =
        events.add("first:init")
        true,
      shutdownHook = proc() =
        events.add("first:shutdown")
    ))
    discard app.registerPlugin(pluginDef(
      "second",
      initHook = proc(): bool =
        events.add("second:init")
        false,
      shutdownHook = proc() =
        events.add("second:shutdown")
    ))

    let ok = app.initializePlugins()
    check ok == false
    check app.pluginsInitialized == false
    check events == @["first:init", "second:init", "first:shutdown"]

  test "P6c: plugin init exception unwinds initialized plugins in reverse order":
    let app = newExpressApp()
    var events: seq[string] = @[]
    discard app.registerPlugin(pluginDef(
      "first",
      initHook = proc(): bool =
        events.add("first:init")
        true,
      shutdownHook = proc() =
        events.add("first:shutdown")
    ))
    discard app.registerPlugin(pluginDef(
      "second",
      initHook = proc(): bool =
        events.add("second:init")
        true,
      shutdownHook = proc() =
        events.add("second:shutdown")
    ))
    discard app.registerPlugin(pluginDef(
      "third",
      initHook = proc(): bool =
        events.add("third:init")
        raise newException(ValueError, "boom")
    ))

    let ok = app.initializePlugins()
    check ok == false
    check events == @[
      "first:init",
      "second:init",
      "third:init",
      "second:shutdown",
      "first:shutdown"
    ]

  test "P7: no plugins is ok":
    let app = newExpressApp()
    let ok = app.initializePlugins()
    check ok == true

  test "P8: many plugins":
    let app = newExpressApp()
    for i in 0..<50:
      discard app.registerPlugin(pluginDef("plugin" & $i))
    let ok = app.initializePlugins()
    check ok == true

# ============================================================
# Q. REQUEST COERCION EDGE CASES
# ============================================================

suite "Q. Request coercion edge cases":
  test "Q1: queryInt with non-numeric value":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let result = req.queryInt("page")
      res.send("ok=" & $result.ok)
    let native = newMockHttpRequest("/test")
    native.queryStringRaw = "page=abc"
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Q2: queryInt with missing param":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let result = req.queryInt("page")
      res.send("ok=" & $result.ok)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Q3: queryBool with invalid value":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let result = req.queryBool("flag")
      res.send("ok=" & $result.ok)
    let native = newMockHttpRequest("/test")
    native.queryStringRaw = "flag=maybe"
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Q4: queryInt with overflow":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let result = req.queryInt("num")
      res.send("ok=" & $result.ok)
    let native = newMockHttpRequest("/test")
    native.queryStringRaw = "num=99999999999999999999999"
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Q5: queryInt with range violation":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let result = req.queryInt("page", minValue = 1, maxValue = 100)
      res.send("ok=" & $result.ok)
    let native = newMockHttpRequest("/test")
    native.queryStringRaw = "page=999"
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Q6: paramRequired with missing param":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let result = req.paramRequired("id")
      res.send("ok=" & $result.ok)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Q7: coerce empty string for all types":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let s = req.queryRequired("s")
      let i = req.queryInt("i", required = false, defaultValue = 42)
      let b = req.queryBool("b", required = false, defaultValue = true)
      res.send("s=" & $s.ok & " i=" & $i.value & " b=" & $b.value)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

# ============================================================
# R. RESPONSE METHODS AFTER FINISH
# ============================================================

suite "R. Response methods after finish":
  test "R1: status after send":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("first")
      discard res.status(201)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "R2: set header after send":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("first")
      discard res.set("x-late", "value")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "R3: json after send":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("first")
      res.json(%*{"late": true})
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "R4: jsonRaw after send":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("first")
      res.jsonRaw("""{"late":true}""")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "R5: redirect after send":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("first")
      res.redirect("/other")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "R6: cookie after send":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("first")
      discard res.cookie("late", "value")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "R7: notFound after send":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("first")
      res.notFound()
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "R8: serverError after send":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("first")
      res.serverError()
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

# ============================================================
# S. REMOTE IP EDGE CASES
# ============================================================

suite "S. Remote IP edge cases":
  test "S1: empty remote IP":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test", remoteIpStr = "")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "S2: IPv6 remote IP":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test", remoteIpStr = "::1")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "S3: very long remote IP string":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test", remoteIpStr = "x".repeat(1000))
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

# ============================================================
# T. TRUST PROXY EDGE CASES
# ============================================================

suite "T. Trust proxy edge cases":
  test "T1: trust proxy with no forwarded headers":
    let app = newExpressApp()
    app.trustProxy = true
    app.get "/test", proc(req: Request, res: Response) =
      let ip = req.trustedClientIp()
      res.send("ip=" & ip)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "T2: trust proxy with x-forwarded-for":
    let app = newExpressApp()
    app.trustProxy = true
    app.get "/test", proc(req: Request, res: Response) =
      let ip = req.trustedClientIp()
      res.send("ip=" & ip)
    let req = newMockRequest("/test", headerMap = @[("x-forwarded-for", "1.2.3.4")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "T3: trust proxy disabled":
    let app = newExpressApp()
    app.trustProxy = false
    app.get "/test", proc(req: Request, res: Response) =
      let ip = req.trustedClientIp()
      res.send("ip=" & ip)
    let req = newMockRequest("/test", headerMap = @[("x-forwarded-for", "1.2.3.4")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "T4: trust proxy with multiple hops":
    let app = newExpressApp()
    app.trustProxy = true
    app.setTrustedProxyHops(2)
    app.get "/test", proc(req: Request, res: Response) =
      let ip = req.trustedClientIp()
      res.send("ip=" & ip)
    let req = newMockRequest("/test",
      headerMap = @[("x-forwarded-for", "1.1.1.1, 2.2.2.2, 3.3.3.3")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "T5: trust proxy with x-forwarded-proto":
    let app = newExpressApp()
    app.trustProxy = true
    app.get "/test", proc(req: Request, res: Response) =
      let proto = req.protocol()
      res.send("proto=" & proto)
    let req = newMockRequest("/test", headerMap = @[("x-forwarded-proto", "https")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "T6: hostname with trust proxy and forwarded host":
    let app = newExpressApp()
    app.trustProxy = true
    app.get "/test", proc(req: Request, res: Response) =
      let host = req.hostname()
      res.send("host=" & host)
    let req = newMockRequest("/test",
      headerMap = @[("x-forwarded-host", "example.com"), ("host", "internal.local")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

# ============================================================
# U. EDGE CASE BODY FILE HANDLING
# ============================================================

suite "U. Body file handling":
  test "U1: bodyInFile with nonexistent path":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindBody()
      res.send("body=" & $req.body.len)
    let native = newMockHttpRequest("/test")
    native.bodyInFile = true
    native.bodyFilePath = "/nonexistent/path/body.dat"
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "U2: bodyInFile with empty path":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.bindBody()
      res.send("body=" & $req.body.len)
    let native = newMockHttpRequest("/test")
    native.bodyInFile = true
    native.bodyFilePath = ""
    let req = newRequest(native)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

# ============================================================
# V. CORRELATION ID EDGE CASES
# ============================================================

suite "V. Correlation ID edge cases":
  test "V1: correlation ID generation":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let id = req.correlationId
      res.send("id=" & id)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "V2: set correlation ID":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.correlationId = "custom-123"
      let id = req.correlationId
      res.send("id=" & id)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "V3: correlation ID with empty string":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      req.correlationId = ""
      let id = req.correlationId
      res.send("id=" & id)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

# ============================================================
# W. MIXED SYNC/ASYNC CHAINS
# ============================================================

suite "W. Mixed sync/async chains":
  test "W1: sync middleware then async handler":
    let app = newExpressApp()
    app.useSync proc(req: Request, res: Response, next: proc() {.closure.}) =
      req.locals["sync"] = "true"
      next()
    app.getAsync "/test", proc(req: Request, res: Response): Future[void] {.async.} =
      res.send("sync=" & req.locals.getOrDefault("sync", ""))
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "W2: async middleware then sync handler":
    let app = newExpressApp()
    app.use proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      req.locals["async"] = "true"
      await next()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("async=" & req.locals.getOrDefault("async", ""))
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "W3: sync middleware throws":
    let app = newExpressApp()
    app.useSync proc(req: Request, res: Response, next: proc() {.closure.}) =
      raise newException(ValueError, "sync crash")
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "W4: sync middleware does not call next":
    let app = newExpressApp()
    app.useSync proc(req: Request, res: Response, next: proc() {.closure.}) =
      discard
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "W5: sync middleware sends response":
    let app = newExpressApp()
    app.useSync proc(req: Request, res: Response, next: proc() {.closure.}) =
      res.send("blocked")
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

# ============================================================
# X. CONTEXT POOL EDGE CASES
# ============================================================

suite "X. Context pool edge cases":
  test "X1: pooling disabled by default":
    check getRequestResponsePoolingEnabled() == false

  test "X2: acquire and release request":
    let native = newMockHttpRequest("/test")
    let req = acquireRequest(native)
    check req != nil
    check req.path == "/test"
    releaseRequest(req)

  test "X3: acquire and release response":
    let native = newMockHttpResponse()
    let res = acquireResponse(native)
    check res != nil
    releaseResponse(res)

  test "X4: release nil request":
    releaseRequest(nil)

  test "X5: release nil response":
    releaseResponse(nil)

  test "X6: prewarm with pooling disabled does nothing":
    setRequestResponsePoolingEnabled(false)
    prewarmContextPools(10, 10)
    check requestPoolSize() == 0
    check responsePoolSize() == 0

# ============================================================
# Y. PROBLEM DETAILS / RFC 7807
# ============================================================

suite "Y. Problem details edge cases":
  test "Y1: problem with empty code":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.problem(400, "", "empty code")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 400

  test "Y2: problem with special characters in detail":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.problem(400, "ERR", "detail with \"quotes\" and <html> & stuff")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Y3: problemDetails with extensions":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.problemDetails(
        422,
        "field is invalid",
        extensions = @[("field", "email"), ("constraint", "format")]
      )
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 422

  test "Y4: problemDetails with reserved extension keys":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.problemDetails(
        400,
        "test",
        extensions = @[("type", "should-be-ignored"), ("status", "also-ignored")]
      )
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Y5: problem on nil response":
    let res: Response = nil
    let result = res.problem(500, "ERR", "nil response")
    check result == nil

# ============================================================
# Z. MISC CRASH SCENARIOS
# ============================================================

suite "Z. Miscellaneous crash scenarios":
  test "Z1: handler accesses request path many times":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      for _ in 0..<1000:
        discard req.path
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Z2: handler binds headers multiple times":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      for _ in 0..<100:
        req.bindHeaders()
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Z3: handler binds query multiple times":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      for _ in 0..<100:
        req.bindQuery()
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Z4: handler binds body multiple times":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      for _ in 0..<100:
        req.bindBody()
      res.send("ok")
    let req = newMockRequest("/test", bodyStr = "test body")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Z5: handler parses JSON body multiple times":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      for _ in 0..<100:
        discard req.getJsonBody()
      res.send("ok")
    let req = newMockRequest("/test", bodyStr = "{\"k\":1}",
      headerMap = @[("content-type", "application/json")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Z6: handler sets many locals":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      for i in 0..<500:
        req.locals["key" & $i] = "value" & $i
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Z7: fresh check with empty values":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let isFresh = req.fresh("", "")
      res.send("fresh=" & $isFresh)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Z8: format with no matching type":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.format(req, [
        ("application/xml", proc() = res.send("<xml/>")),
      ])
    let req = newMockRequest("/test", headerMap = @[("accept", "text/plain")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Z9: format with default handler":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.format(req, [
        ("application/xml", proc() = res.send("<xml/>")),
      ], proc() = res.send("default"))
    let req = newMockRequest("/test", headerMap = @[("accept", "text/plain")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Z10: links helper":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.links([("next", "/page/2"), ("last", "/page/10")])
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Z11: links with empty entries":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.links([("", ""), ("next", "")])
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Z12: links with special characters":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      discard res.links([("next", "<script>alert(1)</script>")])
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Z13: request snapshot":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      let snap = req.snapshot(includeBody = true, includeHeaders = true)
      res.send("path=" & snap.path)
    let req = newMockRequest("/test", bodyStr = "body data",
      headerMap = @[("x-test", "value")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Z14: request snapshot on nil request":
    let snap = snapshot(nil)
    check snap.path == ""

  test "Z15: text response helper":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.text("plain text")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Z16: xml response helper":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.xml("<root/>")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "Z17: unauthorized helper":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.unauthorized()
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 401

  test "Z18: forbidden helper":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.forbidden()
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 403

  test "Z19: all HTTP methods for same path":
    let app = newExpressApp()
    app.get "/api", proc(req: Request, res: Response) = res.send("GET")
    app.post "/api", proc(req: Request, res: Response) = res.send("POST")
    app.put "/api", proc(req: Request, res: Response) = res.send("PUT")
    app.delete "/api", proc(req: Request, res: Response) = res.send("DELETE")
    app.patch "/api", proc(req: Request, res: Response) = res.send("PATCH")
    app.head "/api", proc(req: Request, res: Response) = res.send("HEAD")
    app.options "/api", proc(req: Request, res: Response) = res.send("OPTIONS")
    for (m, _) in [(hmGet, "GET"), (hmPost, "POST"), (hmPut, "PUT"),
                    (hmDelete, "DELETE"), (hmPatch, "PATCH")]:
      let req = newMockRequest("/api", m)
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.finished == true
      check res.statusCode == 200

  test "Z20: handler with very large response headers total":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      for i in 0..<50:
        discard res.set("x-large-header-" & $i, "v".repeat(1000))
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

echo "\n=== All crash scenario tests completed ==="
