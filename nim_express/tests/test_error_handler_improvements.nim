import std/[unittest, asyncdispatch, strutils, envVars]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/error_handler

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

proc capturedResponseBody(res: Response): string =
  let raw = res.native.capturedRaw
  let bodyStart = raw.find("\r\n\r\n")
  if bodyStart >= 0:
    raw[bodyStart + 4 ..^ 1]
  else:
    ""

let crashHandler = proc(req: Request, res: Response): Future[void] {.async.} =
  raise newException(ValueError, "boom")

let okHandler = proc(req: Request, res: Response): Future[void] {.async.} =
  if not res.finished:
    res.status(200)
    res.send("ok")

suite "error_handler unit":
  test "errorHandlerProblemType maps RFC 7807 type URIs":
    check errorHandlerProblemType(400) == "https://tools.ietf.org/html/rfc7231#section-6.5.1"
    check errorHandlerProblemType(404) == "https://tools.ietf.org/html/rfc7231#section-6.5.4"
    check errorHandlerProblemType(500) == "https://tools.ietf.org/html/rfc7231#section-6.6.1"
    check errorHandlerProblemType(200) == "about:blank"

  test "errorHandlerTitle maps status titles":
    check errorHandlerTitle(404) == "Not Found"
    check errorHandlerTitle(500) == "Internal Server Error"
    check errorHandlerTitle(418) == "Error"
    check errorHandlerTitle(0) == "Error"

  test "errorHandlerSanitizeTrace strips control chars, keeps newlines (ISSUE-5)":
    check errorHandlerSanitizeTrace("") == ""
    check errorHandlerSanitizeTrace("x\ny") == "x\ny"
    check errorHandlerSanitizeTrace("a\x01b\n\rcd\x7f") == "a b\n cd "
    check errorHandlerSanitizeTrace("clean") == "clean"

  test "errorHandlerBody builds problem+json (zero-alloc, ISSUE-4)":
    let b1 = errorHandlerBody(404, "Not Found", false, "", "")
    check b1.find("\"type\":\"https://tools.ietf.org/html/rfc7231#section-6.5.4\"") >= 0
    check b1.find("\"title\":\"Not Found\"") >= 0
    check b1.find("\"status\":404") >= 0
    check b1.find("\"detail\":\"Not Found\"") >= 0
    check b1.find("error_type") < 0
    check b1.find("instance") < 0

  test "errorHandlerBody includes error_type + instance in dev shape":
    let b2 = errorHandlerBody(500, "boom", true, "ValueError", "req-123")
    check b2.find("\"status\":500") >= 0
    check b2.find("\"detail\":\"boom\"") >= 0
    check b2.find("\"error_type\":\"ValueError\"") >= 0
    check b2.find("\"instance\":\"req-123\"") >= 0

  test "errorHandlerBody omits empty detail":
    let b3 = errorHandlerBody(404, "", false, "", "")
    check b3.find("\"detail\"") < 0

suite "error_handler integration":
  test "catches CatchableError and returns 500 problem+json (regression)":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = errorHandler()
    runMiddlewareChain(@[mw], req, res, crashHandler)
    check res.statusCode == 500
    check res.finished
    check res.get("content-type").find("application/problem+json") >= 0
    let body = capturedResponseBody(res)
    check body.find("\"status\":500") >= 0
    check body.find("\"title\":\"Internal Server Error\"") >= 0

  test "preserves 4xx status set before the error (regression)":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = errorHandler()
    let handler = proc(req: Request, res: Response): Future[void] {.async.} =
      res.statusCode = 422
      raise newException(ValueError, "invalid input")
    runMiddlewareChain(@[mw], req, res, handler)
    check res.statusCode == 422
    check capturedResponseBody(res).find("\"status\":422") >= 0

  test "passes through a successful handler (regression)":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = errorHandler()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "dev mode under explicit development env includes detail + error_type (ISSUE-2)":
    let oldEnv = getEnv("NIM_EXPRESS_ENV")
    putEnv("NIM_EXPRESS_ENV", "development")
    let opts = ErrorHandlerOptions(devMode: true, logErrors: false)
    let mw = errorHandler(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, crashHandler)
    putEnv("NIM_EXPRESS_ENV", oldEnv)
    check res.statusCode == 500
    let body = capturedResponseBody(res)
    # In async Nim e.msg carries the appended async traceback, so the detail
    # is "boom\nAsync traceback:..."; assert the message is present, not exact.
    check body.find("boom") >= 0
    check body.find("\"error_type\":\"ValueError\"") >= 0

  test "devMode without explicit development env redacts detail (ISSUE-2)":
    let oldEnv = getEnv("NIM_EXPRESS_ENV")
    putEnv("NIM_EXPRESS_ENV", "")
    let opts = ErrorHandlerOptions(devMode: true, logErrors: false)
    let mw = errorHandler(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, crashHandler)
    putEnv("NIM_EXPRESS_ENV", oldEnv)
    check res.statusCode == 500
    let body = capturedResponseBody(res)
    check body.find("boom") < 0
    check body.find("error_type") < 0
    check body.find("\"detail\":\"Internal Server Error\"") >= 0

  test "requestId from locals becomes the instance field (regression)":
    let req = newMockRequest()
    req.locals["requestId"] = "req-xyz"
    let res = newMockResponse()
    let mw = errorHandler(ErrorHandlerOptions(devMode: false, logErrors: false))
    runMiddlewareChain(@[mw], req, res, crashHandler)
    check res.statusCode == 500
    check capturedResponseBody(res).find("\"instance\":\"req-xyz\"") >= 0
