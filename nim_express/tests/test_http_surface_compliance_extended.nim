import std/[unittest, strutils]

import ../src/nim_express/[response, types, windowing]

proc makeResponse(httpMethod: HttpMethod = hmGet): Response =
  var nativeRes: HttpResponse
  new(nativeRes)
  nativeRes.requestMethod = httpMethod
  newResponse(nativeRes)

suite "HTTP surface compliance guards (extended)":
  test "status line builder preserves known and unknown status codes":
    check getStatusLine(429) == "HTTP/1.1 429 Too Many Requests\r\n"
    check getStatusLine(422) == "HTTP/1.1 422 Unprocessable Content\r\n"
    check getStatusLine(499) == "HTTP/1.1 499 Unknown\r\n"
    check getStatusLine(599) == "HTTP/1.1 599 Unknown\r\n"

  test "header-name sanitizer accepts RFC token punctuation set":
    let punctuationToken = "x-!#$%&'*+-.^_`|~"
    check sanitizeHeaderName(punctuationToken) == punctuationToken
    check sanitizeHeaderName("X-!#$%&'*+-.^_`|~") == punctuationToken
    check sanitizeHeaderName("x-@bad") == ""

  test "append combines comma-join headers but preserves Set-Cookie lines":
    let res = makeResponse()

    discard res.append("Vary", "Accept-Encoding")
    discard res.append("Vary", "Origin")
    check res.get("vary") == "Accept-Encoding, Origin"

    discard res.append("Set-Cookie", "a=1; Path=/")
    discard res.append("Set-Cookie", "b=2; Path=/")
    check res.get("set-cookie") == "a=1; Path=/"
    check res.setCookies.len == 2
    check res.setCookies[0] == "a=1; Path=/"
    check res.setCookies[1] == "b=2; Path=/"

  test "Transfer-Encoding header is blocked on framed send paths":
    let res = makeResponse()
    discard res.set("Transfer-Encoding", "chunked")
    discard res.append("Transfer-Encoding", "gzip")
    check res.get("transfer-encoding") == ""

  test "windowed range helper emits RFC 9110 style Content-Range values":
    let res206 = makeResponse()
    discard res206.applyWindowedItemsDecision(
      WindowedItemsDecision(statusCode: 206, start: 10, finish: 19, total: 200),
      unit = "items"
    )
    check res206.statusCode == 206
    check res206.get("accept-ranges") == "items"
    check res206.get("content-range") == "items 10-19/200"
    check res206.get("vary").contains("range")

    let res416 = makeResponse()
    discard res416.applyWindowedItemsDecision(
      WindowedItemsDecision(statusCode: 416, start: 0, finish: 0, total: 200),
      unit = "items"
    )
    check res416.statusCode == 416
    check res416.get("content-range") == "items */200"

  test "header-value sanitizer rejects control bytes except HTAB and allows obs-text":
    check sanitizeHeaderValue("ok\tvalue") == "ok\tvalue"
    check sanitizeHeaderValue("ok\x80obs") == "ok\x80obs"
    check sanitizeHeaderValue("bad\x01ctl") == ""
    check sanitizeHeaderValue("bad\x7Fdel") == ""
    check sanitizeHeaderValue("bad\r\nsplit") == ""

  test "Response.set and append drop invalid control-byte values":
    let res = makeResponse()
    discard res.set("X-Test", "ok\x01bad")
    check res.get("x-test") == ""

    discard res.append("Vary", "Accept-Encoding")
    discard res.append("Vary", "bad\x7Fvalue")
    check res.get("vary") == "Accept-Encoding"

  test "dynamic HEAD responses emit representation content-length without body":
    let textRes = makeResponse(hmHead)
    textRes.text("hello")
    check textRes.native.capturedBody == ""
    check textRes.native.capturedRaw.toLowerAscii().contains("content-length: 5\r\n")

    let jsonRes = makeResponse(hmHead)
    jsonRes.jsonRaw("""{"ok":true}""")
    check jsonRes.native.capturedBody == ""
    check jsonRes.native.capturedRaw.toLowerAscii().contains("content-length: 11\r\n")

    let htmlRes = makeResponse(hmHead)
    htmlRes.sendHtmlBody("<p>ok</p>")
    check htmlRes.native.capturedBody == ""
    check htmlRes.native.capturedRaw.toLowerAscii().contains("content-length: 9\r\n")

  test "HTML no-body status responses omit entity headers and body":
    for code in [101, 204, 304]:
      let res = makeResponse()
      discard res.status(code)
      res.sendHtmlBody("<p>must not be sent</p>")
      let raw = res.native.capturedRaw.toLowerAscii()
      check res.native.capturedBody == ""
      check not raw.contains("content-type:")
      check not raw.contains("content-length:")
      check raw.contains($code)

  test "generic no-body status responses omit entity headers and body":
    for code in [101, 204, 304]:
      block:
        let res = makeResponse()
        discard res.status(code)
        res.send("must not be sent")
        let raw = res.native.capturedRaw.toLowerAscii()
        check res.native.capturedBody == ""
        check not raw.contains("content-type:")
        check not raw.contains("content-length:")
        check raw.contains($code)
      block:
        let res = makeResponse()
        discard res.status(code)
        res.text("must not be sent")
        let raw = res.native.capturedRaw.toLowerAscii()
        check res.native.capturedBody == ""
        check not raw.contains("content-type:")
        check not raw.contains("content-length:")
        check raw.contains($code)
      block:
        let res = makeResponse()
        discard res.status(code)
        res.jsonRaw("""{"must":"not be sent"}""")
        let raw = res.native.capturedRaw.toLowerAscii()
        check res.native.capturedBody == ""
        check not raw.contains("content-type:")
        check not raw.contains("content-length:")
        check raw.contains($code)

  test "clearCookie emits expiration attributes for reliable deletion":
    let res = makeResponse()
    discard res.clearCookie("session", domain = ".example.com")
    check res.setCookies.len == 1
    check res.setCookies[0].contains("session=")
    check res.setCookies[0].contains("Max-Age=-1")
    check res.setCookies[0].contains("Expires=Thu, 01 Jan 1970 00:00:00 GMT")
    check res.setCookies[0].contains("Domain=.example.com")
