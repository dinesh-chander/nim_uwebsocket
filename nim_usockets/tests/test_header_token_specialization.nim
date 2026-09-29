import std/unittest
import ../src/nim_usockets/http

when not defined(nimUwebsocketsTest):
  {.error: "Compile this test with -d:nimUwebsocketsTest".}

proc buildRequest(httpMethod: string, extraHeaders = "", body = ""): string =
  result = httpMethod & " /demo HTTP/1.1\r\n"
  result.add("Host: example.com\r\n")
  if extraHeaders.len > 0:
    result.add(extraHeaders)
  result.add("\r\n")
  result.add(body)

suite "Header token specialization":
  test "common methods stay recognized with RFC-safe fallback":
    let knownMethods = [
      ("GET", hmGet),
      ("POST", hmPost),
      ("PUT", hmPut),
      ("PATCH", hmPatch),
      ("DELETE", hmDelete),
      ("HEAD", hmHead),
      ("OPTIONS", hmOptions),
      ("TRACE", hmTrace),
      ("CONNECT", hmConnect)
    ]
    for (rawMethod, expectedMethod) in knownMethods:
      let parsed = parseHttpRequestForTest(buildRequest(rawMethod))
      check parsed.ok
      check parsed.parseError == false
      check parsed.req.methodKind == expectedMethod

    let unknownMethod = parseHttpRequestForTest(buildRequest("custom"))
    check unknownMethod.ok == false
    check unknownMethod.parseError
    check unknownMethod.parseStatusCode == 501

    let invalidToken = parseHttpRequestForTest(buildRequest("B@D"))
    check invalidToken.ok == false
    check invalidToken.parseError
    check invalidToken.parseStatusCode == 400

  test "full headers mode keeps known fast path and unknown fallback":
    let extraHeaders =
      "ConNection: keep-alive, Upgrade\r\n" &
      "UpGraDe: websocket\r\n" &
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
      "Sec-WebSocket-Version: 13\r\n" &
      "Content-Type: text/plain\r\n" &
      "Cookie: a=b\r\n" &
      "X-Custom-Token: abc123\r\n"
    let parsed = parseHttpRequestForTest(buildRequest("GET", extraHeaders), minimalHeaders = false)
    check parsed.ok
    check parsed.parseError == false
    check parsed.req.isWebSocketUpgrade()
    check parsed.req.headers != nil
    check parsed.req.headers.getOrDefault("connection", "") == "keep-alive, Upgrade"
    check parsed.req.headers.getOrDefault("upgrade", "") == "websocket"
    check parsed.req.headers.getOrDefault("sec-websocket-key", "") == "dGhlIHNhbXBsZSBub25jZQ=="
    check parsed.req.headers.getOrDefault("sec-websocket-version", "") == "13"
    check parsed.req.headers.getOrDefault("content-type", "") == "text/plain"
    check parsed.req.headers.getOrDefault("cookie", "") == "a=b"
    check parsed.req.headers.getOrDefault("x-custom-token", "") == "abc123"

  test "minimal headers mode materializes unknown keys when requested":
    let extraHeaders =
      "ConNection: keep-alive, Upgrade\r\n" &
      "UpGraDe: websocket\r\n" &
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
      "Sec-WebSocket-Version: 13\r\n" &
      "Content-Type: text/plain\r\n" &
      "Cookie: a=b\r\n" &
      "Origin: https://app.example\r\n" &
      "X-Custom-Token: abc123\r\n"
    let parsed = parseHttpRequestForTest(buildRequest("GET", extraHeaders), minimalHeaders = true)
    check parsed.ok
    check parsed.parseError == false
    check parsed.req.isWebSocketUpgrade()
    check parsed.req.headers != nil
    check parsed.req.headers.getOrDefault("upgrade", "") == "websocket"
    check parsed.req.headers.getOrDefault("sec-websocket-key", "") == "dGhlIHNhbXBsZSBub25jZQ=="
    check parsed.req.headers.getOrDefault("sec-websocket-version", "") == "13"
    check parsed.req.headers.getOrDefault("content-type", "") == "text/plain"
    check parsed.req.headers.getOrDefault("cookie", "") == "a=b"
    check parsed.req.headers.getOrDefault("origin", "") == "https://app.example"
    check parsed.req.headers.getOrDefault("x-custom-token", "") == "abc123"
