import std/[strutils, unittest]

import ../src/nim_express/[response, types]

suite "HTTP surface compliance guards":
  test "header-name sanitizer enforces RFC token grammar":
    check sanitizeHeaderName("X-Test") == "x-test"
    check sanitizeHeaderName("etag") == "etag"
    check sanitizeHeaderName("") == ""
    check sanitizeHeaderName("Bad Header") == ""
    check sanitizeHeaderName("Bad:Header") == ""
    check sanitizeHeaderName("Bad\tHeader") == ""

  test "header-value sanitizer blocks response splitting bytes":
    check sanitizeHeaderValue("ok") == "ok"
    check sanitizeHeaderValue("") == ""
    check sanitizeHeaderValue("line\rbreak") == ""
    check sanitizeHeaderValue("line\nbreak") == ""
    check sanitizeHeaderValue("nul\0byte") == ""

  test "Response.set drops unsafe headers and preserves safe ones":
    var nativeRes: HttpResponse
    new(nativeRes)
    nativeRes.requestMethod = hmGet
    let res = newResponse(nativeRes)

    discard res.set("X-Good", "ok")
    check res.headersInited
    check res.headers.getOrDefault("x-good", "") == "ok"

    # RFC 9110 field-name token: spaces are invalid and must be ignored.
    discard res.set("Bad Header", "blocked")
    check res.headers.getOrDefault("bad header", "") == ""

    # RFC 9112 response splitting guard: reject CR/LF and NUL in values.
    discard res.set("X-Injected", "ok\r\nX-Evil: yes")
    discard res.set("X-Nul", "ok\0evil")
    check res.headers.getOrDefault("x-injected", "") == ""
    check res.headers.getOrDefault("x-nul", "") == ""

  test "Response.setTrusted still sanitizes exported header names":
    var nativeRes: HttpResponse
    new(nativeRes)
    nativeRes.requestMethod = hmGet
    let res = newResponse(nativeRes)

    discard res.setTrusted("X-Trusted", "ok")
    check res.get("x-trusted") == "ok"

    discard res.setTrusted("x\r\nbad: 1", "ok")
    discard res.setTrusted("Transfer-Encoding", "chunked")
    res.send("body")

    check not nativeRes.capturedRaw.contains("bad: 1")
    check not nativeRes.capturedRaw.contains("transfer-encoding")
