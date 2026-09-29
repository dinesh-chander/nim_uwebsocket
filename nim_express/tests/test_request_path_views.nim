import std/unittest
import ../src/nim_express/[types, request]

proc makeNative(
  path: string,
  rawQuery: string = "",
  headers: openArray[(string, string)] = []
): HttpRequest =
  new(result)
  result.methodKind = hmGet
  result.path = path
  result.queryStringRaw = rawQuery
  result.query = nil
  if headers.len > 0:
    result.headers = newFastMap[string]()
    discard result.headers.reserve(max(8, headers.len * 2))
    for (key, value) in headers:
      result.headers[key] = value

template withFreshRequestPool(body: untyped) =
  let poolingWasEnabled = getRequestResponsePoolingEnabled()
  setRequestResponsePoolingEnabled(false)
  setRequestResponsePoolingEnabled(true)
  try:
    body
  finally:
    setRequestResponsePoolingEnabled(false)
    setRequestResponsePoolingEnabled(poolingWasEnabled)

suite "Request path borrowed view":
  test "path accessor borrows native path metadata":
    let native = makeNative("/todos")
    let req = newRequest(native)
    check req.path == "/todos"
    check cast[uint](unsafeAddr req.path[0]) == cast[uint](unsafeAddr native.path[0])

  test "pooled request path tracks new native request":
    let native1 = makeNative("/one")
    let req1 = acquireRequest(native1)
    check req1.path == "/one"
    releaseRequest(req1)

    let native2 = makeNative("/two")
    let req2 = acquireRequest(native2)
    check req2.path == "/two"
    releaseRequest(req2)

  test "lazy query parsing remains correct after reuse":
    let native1 = makeNative("/search", "q=first")
    let req1 = acquireRequest(native1)
    check req1.queryParam("q") == "first"
    check req1.query == nil
    releaseRequest(req1)

    let native2 = makeNative("/search")
    let req2 = acquireRequest(native2)
    check req2.path == "/search"
    check req2.queryParam("q", "missing") == "missing"
    releaseRequest(req2)

  test "pooled request reuse clears bound query and parsed cookies":
    withFreshRequestPool:
      let native1 = makeNative(
        "/search",
        "q=first",
        [("cookie", "session=abc; theme=dark")]
      )
      let req1 = acquireRequest(native1)
      req1.bindQuery()
      check req1.query.getOrDefault("q", "") == "first"
      check req1.getCookie("session") == "abc"
      releaseRequest(req1)

      let native2 = makeNative("/search")
      let req2 = acquireRequest(native2)
      check req2 == req1
      check req2.queryParam("q", "missing") == "missing"
      check req2.getCookie("session") == ""
      check req2.cookies.len == 0
      releaseRequest(req2)

  test "queryParam scans raw query without binding full map and keeps last matching value":
    let native = makeNative("/search", "page=1&q=first&q=second&empty&tail=done")
    let req = newRequest(native)
    check req.query == nil
    check req.queryParam("q", "missing") == "second"
    check req.queryParam("empty", "missing") == ""
    check req.queryParam("tail", "missing") == "done"
    check req.query == nil

  test "request helpers treat +json content types as JSON":
    let native = makeNative("/patch")
    native.headers = newFastMap[string]()
    native.headers["content-type"] = "application/merge-patch+json; charset=utf-8"
    native.body = """{"ok":true}"""
    let req = newRequest(native)
    check req.isJson()
    let body = req.getJsonBody()
    check body != nil
    check body["ok"].getBool()

  test "forwarded proxy helpers stay correct on borrowed header views":
    let native = makeNative("/proxy")
    native.remoteIp = "10.0.0.1"
    native.headers = newFastMap[string]()
    native.headers["x-forwarded-for"] = "198.51.100.10, 203.0.113.90"
    native.headers["x-forwarded-proto"] = "https"
    native.headers["x-forwarded-host"] = "app.example.com:8443"
    let req = newRequest(native)
    req.trustProxyEnabled = true
    req.trustedProxyHopCount = 1
    check req.trustedClientIp() == "198.51.100.10"
    check req.protocol() == "https"
    check req.hostname() == "app.example.com"
