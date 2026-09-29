import std/[unittest, strutils]
import ../src/nim_usockets/http

when not defined(nimUwebsocketsTest):
  {.error: "Compile this test with -d:nimUwebsocketsTest".}

suite "HTTP parser RFC extended compliance":
  test "request-target forms parse correctly (RFC 9112 section 3.2)":
    let optionsStar =
      "OPTIONS * HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "\r\n"
    let absoluteForm =
      "GET http://example.test/alpha/beta?x=1&y=2 HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "\r\n"
    let connectAuthority =
      "CONNECT example.test:443 HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "\r\n"

    for minimalHeaders in [false, true]:
      let parsedOptions = parseHttpRequestForTest(optionsStar, minimalHeaders = minimalHeaders)
      check parsedOptions.ok
      check parsedOptions.parseError == false
      check parsedOptions.req.methodKind == hmOptions
      check parsedOptions.req.path == "*"

      let parsedAbsolute = parseHttpRequestForTest(absoluteForm, minimalHeaders = minimalHeaders)
      check parsedAbsolute.ok
      check parsedAbsolute.parseError == false
      check parsedAbsolute.req.methodKind == hmGet
      check parsedAbsolute.req.path.startsWith("http://example.test/alpha/beta")
      check parsedAbsolute.req.queryStringRaw == "x=1&y=2"

      let parsedConnect = parseHttpRequestForTest(connectAuthority, minimalHeaders = minimalHeaders)
      check parsedConnect.ok
      check parsedConnect.parseError == false
      check parsedConnect.req.methodKind == hmConnect
      check parsedConnect.req.path == "example.test:443"

  test "Host requirements enforce HTTP/1.1 and allow HTTP/1.0 fallback (RFC 9112 section 3.2)":
    let missingHostHttp11 = "GET / HTTP/1.1\r\n\r\n"
    let missingHostHttp10 = "GET / HTTP/1.0\r\n\r\n"
    let emptyHostHttp11 = "GET / HTTP/1.1\r\nHost:\r\n\r\n"
    let absoluteNoHostHttp11 = "GET http://example.test/a HTTP/1.1\r\n\r\n"

    for minimalHeaders in [false, true]:
      let noHost11 = parseHttpRequestForTest(missingHostHttp11, minimalHeaders = minimalHeaders)
      check noHost11.ok == false
      check noHost11.parseError
      check noHost11.parseStatusCode == 400

      let noHost10 = parseHttpRequestForTest(missingHostHttp10, minimalHeaders = minimalHeaders)
      check noHost10.ok
      check noHost10.parseError == false

      let emptyHost = parseHttpRequestForTest(emptyHostHttp11, minimalHeaders = minimalHeaders)
      check emptyHost.ok == false
      check emptyHost.parseError
      check emptyHost.parseStatusCode == 400

      let absoluteNoHost = parseHttpRequestForTest(absoluteNoHostHttp11, minimalHeaders = minimalHeaders)
      check absoluteNoHost.ok == false
      check absoluteNoHost.parseError
      check absoluteNoHost.parseStatusCode == 400

  test "Expect handling follows configured mode (RFC 9110 section 10.1.1)":
    let expectContinue =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Expect: 100-continue\r\n" &
      "Content-Length: 4\r\n" &
      "\r\n" &
      "ABCD"
    let expectUnsupported =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Expect: fancy-feature\r\n" &
      "Content-Length: 4\r\n" &
      "\r\n" &
      "ABCD"

    let strict = parseHttpRequestForTest(
      expectContinue,
      minimalHeaders = false,
      expectContinueMode = ecmStrictReject
    )
    check strict.ok == false
    check strict.parseError
    check strict.parseStatusCode == 417

    let allow = parseHttpRequestForTest(
      expectContinue,
      minimalHeaders = false,
      expectContinueMode = ecmAllow100Continue
    )
    check allow.ok
    check allow.parseError == false
    check allow.req.body == "ABCD"

    for mode in [ecmStrictReject, ecmAllow100Continue]:
      let unsupported = parseHttpRequestForTest(
        expectUnsupported,
        minimalHeaders = false,
        expectContinueMode = mode
      )
      check unsupported.ok == false
      check unsupported.parseError
      check unsupported.parseStatusCode == 417

  test "header size and count limits produce 431 (RFC 9112 section 5.4)":
    let manyHeaders =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "X-A: 1\r\n" &
      "X-B: 2\r\n" &
      "X-C: 3\r\n" &
      "\r\n"
    let longHeaderLine =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "X-Long: " & repeat("a", 80) & "\r\n" &
      "\r\n"
    let largeHeaderBytes =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "X-1: " & repeat("b", 40) & "\r\n" &
      "X-2: " & repeat("c", 40) & "\r\n" &
      "\r\n"

    let byCount = parseHttpRequestForTest(manyHeaders, maxHeaderCount = 2)
    check byCount.ok == false
    check byCount.parseError
    check byCount.parseStatusCode == 431

    let byLine = parseHttpRequestForTest(longHeaderLine, maxHeaderLineBytes = 24)
    check byLine.ok == false
    check byLine.parseError
    check byLine.parseStatusCode == 431

    let byBytes = parseHttpRequestForTest(largeHeaderBytes, maxHeaderBytes = 64)
    check byBytes.ok == false
    check byBytes.parseError
    check byBytes.parseStatusCode == 431

  test "framing syntax honors valid OWS and rejects invalid field-name separators":
    let validContentLengthWithTab =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Content-Length:\t4\r\n" &
      "\r\n" &
      "ABCD"
    let invalidFieldNameSpacing =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Content-Length : 4\r\n" &
      "\r\n" &
      "ABCD"
    let chunkedCaseInsensitive =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: Chunked\r\n" &
      "\r\n" &
      "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"

    for minimalHeaders in [false, true]:
      let goodCl = parseHttpRequestForTest(validContentLengthWithTab, minimalHeaders = minimalHeaders)
      check goodCl.ok
      check goodCl.parseError == false
      check goodCl.req.body == "ABCD"

      let badSep = parseHttpRequestForTest(invalidFieldNameSpacing, minimalHeaders = minimalHeaders)
      check badSep.ok == false
      check badSep.parseError
      check badSep.parseStatusCode == 400

      let chunked = parseHttpRequestForTest(chunkedCaseInsensitive, minimalHeaders = minimalHeaders)
      check chunked.ok
      check chunked.parseError == false
      check chunked.req.body == "Wikipedia"

  test "HTTP version handling is strict to supported versions":
    let http10 = "GET / HTTP/1.0\r\n\r\n"
    let http11 = "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n"
    let http20 = "GET / HTTP/2.0\r\nHost: example.test\r\n\r\n"

    for minimalHeaders in [false, true]:
      let v10 = parseHttpRequestForTest(http10, minimalHeaders = minimalHeaders)
      check v10.ok
      check v10.parseError == false
      check v10.req.httpVersion == "HTTP/1.0"

      let v11 = parseHttpRequestForTest(http11, minimalHeaders = minimalHeaders)
      check v11.ok
      check v11.parseError == false
      check v11.req.httpVersion == "HTTP/1.1"

      let v20 = parseHttpRequestForTest(http20, minimalHeaders = minimalHeaders)
      check v20.ok == false
      check v20.parseError
      check v20.parseStatusCode == 505

  test "header octet rules reject control bytes but allow obs-text":
    let obsTextPayload =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "X-Obs: ok\x80\xFF\r\n" &
      "\r\n"
    let controlInValuePayload =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "X-Bad: ok\x01bad\r\n" &
      "\r\n"
    let controlInNamePayload =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "X-\tBad: 1\r\n" &
      "\r\n"

    let obs = parseHttpRequestForTest(obsTextPayload, minimalHeaders = false)
    check obs.ok
    check obs.parseError == false

    for payload in [controlInValuePayload, controlInNamePayload]:
      let parsed = parseHttpRequestForTest(payload, minimalHeaders = false)
      check parsed.ok == false
      check parsed.parseError
      check parsed.parseStatusCode == 400

  test "header storage and lookup are case-insensitive":
    let payload =
      "GET / HTTP/1.1\r\n" &
      "hOsT: example.test\r\n" &
      "X-CuStOm: Value-1\r\n" &
      "\r\n"
    let parsed = parseHttpRequestForTest(payload, minimalHeaders = false)
    check parsed.ok
    check parsed.parseError == false
    check parsed.req.headers.getOrDefault("host", "") == "example.test"
    check parsed.req.headers.getOrDefault("x-custom", "") == "Value-1"

  test "connection persistence follows HTTP version defaults and connection tokens":
    let http11Default =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "\r\n"
    let http11Close =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Connection: close\r\n" &
      "\r\n"
    let http11Upgrade =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Upgrade: websocket\r\n" &
      "Connection: keep-alive, UpGrAdE\r\n" &
      "\r\n"
    let http10Default = "GET / HTTP/1.0\r\n\r\n"
    let http10KeepAlive =
      "GET / HTTP/1.0\r\n" &
      "Connection: keep-alive\r\n" &
      "\r\n"
    let http10CloseWins =
      "GET / HTTP/1.0\r\n" &
      "Connection: keep-alive, close\r\n" &
      "\r\n"

    let p11Default = parseHttpRequestForTest(http11Default, minimalHeaders = false)
    check p11Default.ok
    check p11Default.parseError == false
    check p11Default.req.connectionClose == false

    let p11Close = parseHttpRequestForTest(http11Close, minimalHeaders = false)
    check p11Close.ok
    check p11Close.parseError == false
    check p11Close.req.connectionClose

    let p11Upgrade = parseHttpRequestForTest(http11Upgrade, minimalHeaders = false)
    check p11Upgrade.ok
    check p11Upgrade.parseError == false
    check p11Upgrade.req.isWebSocketUpgrade()
    check p11Upgrade.req.connectionClose == false

    let p10Default = parseHttpRequestForTest(http10Default, minimalHeaders = false)
    check p10Default.ok
    check p10Default.parseError == false
    check p10Default.req.connectionClose

    let p10KeepAlive = parseHttpRequestForTest(http10KeepAlive, minimalHeaders = false)
    check p10KeepAlive.ok
    check p10KeepAlive.parseError == false
    check p10KeepAlive.req.connectionClose == false

    let p10CloseWins = parseHttpRequestForTest(http10CloseWins, minimalHeaders = false)
    check p10CloseWins.ok
    check p10CloseWins.parseError == false
    check p10CloseWins.req.connectionClose

  test "transfer-encoding grammar rejects empty, duplicate chunked, and TE on HTTP/1.0":
    let emptyTe =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding:   \r\n" &
      "\r\n"
    let duplicateChunked =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked, chunked\r\n" &
      "\r\n"
    let teHttp10 =
      "POST /upload HTTP/1.0\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n"

    let parsedEmpty = parseHttpRequestForTest(emptyTe, minimalHeaders = false)
    check parsedEmpty.ok == false
    check parsedEmpty.parseError
    check parsedEmpty.parseStatusCode == 400

    let parsedDup = parseHttpRequestForTest(duplicateChunked, minimalHeaders = false)
    check parsedDup.ok == false
    check parsedDup.parseError
    check parsedDup.parseStatusCode == 400

    let parsed10 = parseHttpRequestForTest(teHttp10, minimalHeaders = false)
    check parsed10.ok == false
    check parsed10.parseError
    check parsed10.parseStatusCode == 400

  test "header-line without colon is rejected as malformed":
    let payload =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "X-Bad-Header\r\n" &
      "\r\n"
    let parsed = parseHttpRequestForTest(payload, minimalHeaders = false)
    check parsed.ok == false
    check parsed.parseError
    check parsed.parseStatusCode == 400

  test "incomplete body for declared Content-Length remains incomplete without hard parse error":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Content-Length: 10\r\n" &
      "\r\n" &
      "abc"
    let parsed = parseHttpRequestForTest(payload, minimalHeaders = false)
    check parsed.ok == false
    check parsed.parseError == false

  test "expect token lists honor 100-continue and reject mixed unsupported expectations":
    let expectOnlyContinue =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Expect: 100-continue, 100-continue\r\n" &
      "Content-Length: 4\r\n" &
      "\r\n" &
      "ABCD"
    let expectMixed =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Expect: 100-continue, fancy-token\r\n" &
      "Content-Length: 4\r\n" &
      "\r\n" &
      "ABCD"

    let allowContinue = parseHttpRequestForTest(
      expectOnlyContinue,
      minimalHeaders = false,
      expectContinueMode = ecmAllow100Continue
    )
    check allowContinue.ok
    check allowContinue.parseError == false
    check allowContinue.req.body == "ABCD"

    let strictContinue = parseHttpRequestForTest(
      expectOnlyContinue,
      minimalHeaders = false,
      expectContinueMode = ecmStrictReject
    )
    check strictContinue.ok == false
    check strictContinue.parseError
    check strictContinue.parseStatusCode == 417

    let mixed = parseHttpRequestForTest(
      expectMixed,
      minimalHeaders = false,
      expectContinueMode = ecmAllow100Continue
    )
    check mixed.ok == false
    check mixed.parseError
    check mixed.parseStatusCode == 417

  test "header value DEL byte is rejected":
    let payload =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "X-Del: bad\x7Fvalue\r\n" &
      "\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseHttpRequestForTest(payload, minimalHeaders = minimalHeaders)
      check parsed.ok == false
      check parsed.parseError
      check parsed.parseStatusCode == 400
