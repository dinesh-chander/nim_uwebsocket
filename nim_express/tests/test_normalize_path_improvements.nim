## Tests for normalize_path middleware improvements.

import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/normalize_path

proc newMockHttpRequest(
  pathVal: string = "/", methodKind: HttpMethod = hmGet, bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1", queryRaw: string = "",
  headerMap: seq[(string, string)] = @[]
): HttpRequest =
  new(result)
  result.path = pathVal
  result.queryStringRaw = queryRaw
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
  remoteIpStr: string = "127.0.0.1", queryRaw: string = ""
): Request =
  let native = newMockHttpRequest(pathVal, methodKind, bodyStr, remoteIpStr,
    queryRaw)
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

suite "resolveDotSegments unit tests":
  test "dot segment resolution table":
    let cases: seq[(string, string)] = @[
      ("", "/"),
      ("/", "/"),
      ("/api/users", "/api/users"),
      ("/api/users/", "/api/users"),
      ("/a/./b", "/a/b"),
      ("/a/../b", "/b"),
      ("/a/b/..", "/a"),
      ("/..", "/"),
      ("/../a", "/a"),
      ("/a/./", "/a"),
      ("/x/./y/../z/.", "/x/z"),
      ("/a/b/../../../c", "/c"),
      ("/a/b/c/../../d", "/a/d"),
      ("/a//b", "/a/b"),
      (".", "/"),
      ("..", "/"),
      ("./foo", "/foo"),
      ("../bar", "/bar"),
      ("a/./b", "/a/b"),
    ]
    for (input, expected) in cases:
      check resolveDotSegments(input) == expected

  test "deep path with more than 16 segments is preserved":
    var deep = ""
    for k in 1 .. 20:
      deep.add("/s" & $k)
    check resolveDotSegments(deep) == deep

  test "deep path with dot segments resolves":
    var deep = ""
    for k in 1 .. 18:
      deep.add("/s" & $k)
    deep.add("/../../tail")
    var expected = ""
    for k in 1 .. 16:
      expected.add("/s" & $k)
    expected.add("/tail")
    check resolveDotSegments(deep) == expected

suite "mergeSlashes unit tests":
  test "slash merge table":
    let cases: seq[(string, string)] = @[
      ("", ""),
      ("/", "/"),
      ("//", "/"),
      ("///", "/"),
      ("/a//b", "/a/b"),
      ("/a///b///c", "/a/b/c"),
      ("/a//", "/a/"),
      ("//a//b", "/a/b"),
      ("/a/b/c", "/a/b/c"),
    ]
    for (input, expected) in cases:
      check mergeSlashes(input) == expected

suite "normalizePath middleware chain tests":
  test "clean path passes through without redirect":
    var called = false
    let req = newMockRequest("/api/users")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res, flagHandler(addr called))
    check res.statusCode == 200
    check called
    check res.get("Location") == ""

  test "root path passes through":
    var called = false
    let req = newMockRequest("/")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res, flagHandler(addr called))
    check res.statusCode == 200
    check called
    check res.get("Location") == ""

  test "trailing slash is trimmed and location set":
    var called = false
    let req = newMockRequest("/api/users/")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res, flagHandler(addr called))
    check res.statusCode == 301
    check not called
    check res.get("Location") == "/api/users"

  test "trailing slash trim preserves query string":
    let req = newMockRequest("/api/users/", queryRaw = "a=1&b=2")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/api/users?a=1&b=2"

  test "duplicate slashes are merged":
    let req = newMockRequest("/api//users///data")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/api/users/data"

  test "leading double slash is merged":
    let req = newMockRequest("//api/users")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/api/users"

  test "dot segments are resolved":
    let req = newMockRequest("/api/users/../admin")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/api/admin"

  test "embedded dot segment is resolved":
    let req = newMockRequest("/a/b/./c")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/a/b/c"

  test "dot dot at root is ignored":
    let req = newMockRequest("/../foo")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/foo"

  test "trailing dot dot resolves":
    let req = newMockRequest("/a/b/..")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/a"

  test "path traversal cannot escape root":
    let req = newMockRequest("/a/../../../../etc/passwd")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/etc/passwd"

  test "dot segment resolution preserves query string":
    let req = newMockRequest("/a/../b", queryRaw = "x=1&y=2")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/b?x=1&y=2"

  test "dot segment and double slash combined":
    let req = newMockRequest("/a//./b")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/a/b"

  test "relative dot path is resolved (defense in depth)":
    let req = newMockRequest("./foo")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/foo"

  test "relative parent dot path is resolved (defense in depth)":
    let req = newMockRequest("../bar")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/bar"

  test "append mode adds trailing slash":
    let req = newMockRequest("/api/users")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath(tsmAppend)], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/api/users/"

  test "append mode skips file with extension":
    var called = false
    let req = newMockRequest("/files/report.html")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath(tsmAppend)], req, res,
      flagHandler(addr called))
    check res.statusCode == 200
    check called
    check res.get("Location") == ""

  test "append mode no-op when trailing slash already present":
    var called = false
    let req = newMockRequest("/api/users/")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath(tsmAppend)], req, res,
      flagHandler(addr called))
    check res.statusCode == 200
    check called
    check res.get("Location") == ""

  test "append mode resolves dot segment then appends":
    let req = newMockRequest("/api/./users")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath(tsmAppend)], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/api/users/"

  test "unicode path trailing slash is trimmed":
    let req = newMockRequest("/api/файлы/")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/api/файлы"

  test "merge disabled: trailing slash trim collapses leading double slash":
    let mw = normalizePath(NormalizePathOptions(
      trailingSlash: tsmTrim, mergeDuplicateSlashes: false, redirectCode: 301))
    let req = newMockRequest("//api/users/")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check res.statusCode == 301
    check res.get("Location") == "/api/users"

  test "merge disabled: clean double-slash path without rewrite passes through":
    var called = false
    let mw = normalizePath(NormalizePathOptions(
      trailingSlash: tsmTrim, mergeDuplicateSlashes: false, redirectCode: 301))
    let req = newMockRequest("//api/users")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr called))
    check res.statusCode == 200
    check called

  test "custom redirect code 308 is used":
    let mw = normalizePath(NormalizePathOptions(
      trailingSlash: tsmTrim, mergeDuplicateSlashes: true, redirectCode: 308))
    let req = newMockRequest("/api/")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check res.statusCode == 308
    check res.get("Location") == "/api"

  test "custom redirect code 302 is used":
    let mw = normalizePath(NormalizePathOptions(
      trailingSlash: tsmTrim, mergeDuplicateSlashes: true, redirectCode: 302))
    let req = newMockRequest("/api/")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check res.statusCode == 302

  test "all valid redirect codes are accepted":
    for c in [301, 302, 307, 308]:
      discard normalizePath(NormalizePathOptions(
        trailingSlash: tsmTrim, mergeDuplicateSlashes: true, redirectCode: c))

  test "invalid redirect code raises AssertionDefect":
    expect AssertionDefect:
      discard normalizePath(NormalizePathOptions(
        trailingSlash: tsmTrim, mergeDuplicateSlashes: true, redirectCode: 303))
