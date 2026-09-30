# Regression test: cross-origin redirects must strip credential headers
# (Authorization, Cookie, Proxy-Authorization) while same-origin redirects
# keep them, and non-sensitive headers always survive.
import std/strutils
import nim_fasthttpclient/types
import nim_fasthttpclient/client
import nim_usockets/usockets

var passed = 0
var failed = 0

template check(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failed += 1
    echo "FAIL: ", msg

const Host = "127.0.0.1"
const PortA = 9881
const PortB = 9882

var httpClient: HttpClient
var doneCount = 0
var listenA, listenB: UsListenSocketPtr
var ctxA, ctxB: UsSocketContextPtr

var crossGot = false
var crossStatus = 0
var crossBody = ""

var sameGot = false
var sameStatus = 0
var sameBody = ""

proc rawRequest(data: cstring, length: cint): string =
  if length <= 0:
    return ""
  result = newStringOfCap(int(length))
  result.setLen(int(length))
  moveMem(addr result[0], cast[ptr byte](data), cint(length))

proc requestPath(raw: string): string =
  var i = 0
  while i < raw.len and raw[i] != ' ': inc i
  if i >= raw.len: return ""
  inc i
  let start = i
  while i < raw.len and raw[i] != ' ': inc i
  if start < i:
    result = raw[start ..< i]

proc headEndPos(raw: string): int =
  result = -1
  if raw.len >= 4:
    for i in 0 ..< raw.len - 3:
      if raw[i] == '\r' and raw[i + 1] == '\n' and raw[i + 2] == '\r' and raw[i + 3] == '\n':
        result = i
        break

# Server A redirects: /start-redirect -> cross-origin (B), /start-same -> same-origin (A).
proc onAData(s: UsSocketPtr, data: cstring, length: cint): UsSocketPtr {.cdecl.} =
  let raw = rawRequest(data, length)
  case requestPath(raw)
  of "/start-redirect":
    # keep-alive (1.1 default): closing here would leave a dead connection in
    # the client pool that the next (same-loop) phase could reuse and hang on.
    var resp = "HTTP/1.1 302 Found\r\nLocation: http://" & Host & ":" & $PortB & "/target\r\nContent-Length: 0\r\n\r\n"
    discard us_socket_write(0, s, cstring(resp), cint(resp.len), 0)
  of "/start-same":
    var resp = "HTTP/1.1 302 Found\r\nLocation: http://" & Host & ":" & $PortA & "/final\r\nContent-Length: 0\r\n\r\n"
    discard us_socket_write(0, s, cstring(resp), cint(resp.len), 0)
  else:
    let headEnd = headEndPos(raw)
    let head = if headEnd >= 0: raw[0 ..< headEnd] else: ""
    var resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " & $head.len & "\r\nConnection: close\r\n\r\n"
    resp.add head
    discard us_socket_write(0, s, cstring(resp), cint(resp.len), 0)
    us_socket_shutdown(0, s)
  s

proc onBData(s: UsSocketPtr, data: cstring, length: cint): UsSocketPtr {.cdecl.} =
  let raw = rawRequest(data, length)
  let headEnd = headEndPos(raw)
  let head = if headEnd >= 0: raw[0 ..< headEnd] else: ""
  var resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " & $head.len & "\r\nConnection: close\r\n\r\n"
  resp.add head
  discard us_socket_write(0, s, cstring(resp), cint(resp.len), 0)
  us_socket_shutdown(0, s)
  s

proc noop(s: UsSocketPtr, isClient: cint, ip: cstring, ipLength: cint): UsSocketPtr {.cdecl.} = s
proc noopW(s: UsSocketPtr): UsSocketPtr {.cdecl.} = s
proc noopC(s: UsSocketPtr, code: cint, reason: pointer): UsSocketPtr {.cdecl.} = s
proc noopE(s: UsSocketPtr): UsSocketPtr {.cdecl.} =
  discard us_socket_close(0, s, 0, nil)
  s
proc noopErr(s: UsSocketPtr, code: cint): UsSocketPtr {.cdecl.} = s

proc setupServer(): bool =
  let options = defaultSocketContextOptions()
  ctxA = us_create_socket_context(0, httpClient.loop, 0, options)
  ctxB = us_create_socket_context(0, httpClient.loop, 0, options)
  if ctxA == nil or ctxB == nil:
    return false
  us_socket_context_on_open(0, ctxA, noop)
  us_socket_context_on_data(0, ctxA, onAData)
  us_socket_context_on_writable(0, ctxA, noopW)
  us_socket_context_on_close(0, ctxA, noopC)
  us_socket_context_on_end(0, ctxA, noopE)
  us_socket_context_on_connect_error(0, ctxA, noopErr)
  us_socket_context_on_open(0, ctxB, noop)
  us_socket_context_on_data(0, ctxB, onBData)
  us_socket_context_on_writable(0, ctxB, noopW)
  us_socket_context_on_close(0, ctxB, noopC)
  us_socket_context_on_end(0, ctxB, noopE)
  us_socket_context_on_connect_error(0, ctxB, noopErr)
  listenA = us_socket_context_listen(0, ctxA, Host, cint(PortA), 0, 0)
  listenB = us_socket_context_listen(0, ctxB, Host, cint(PortB), 0, 0)
  listenA != nil and listenB != nil

proc finishIfDone() {.gcsafe.} =
  {.cast(gcsafe).}:
    inc doneCount
    if doneCount == 2:
      if listenA != nil:
        us_listen_socket_close(0, listenA)
      if listenB != nil:
        us_listen_socket_close(0, listenB)
      stopLoop(httpClient)

proc onCrossCb(resp: HttpResponse, err: string) =
  {.cast(gcsafe).}:
    crossGot = true
    crossStatus = resp.statusCode
    crossBody = resp.body
  finishIfDone()

proc onSameCb(resp: HttpResponse, err: string) =
  {.cast(gcsafe).}:
    sameGot = true
    sameStatus = resp.statusCode
    sameBody = resp.body
  finishIfDone()

httpClient = newHttpClient()
initClient(httpClient, ssl = false)
httpClient.defaultTimeoutMs = 5_000   # a stuck request must fail, not hang the suite

# Both requests are independent (separate origins/hops), so they are issued
# up front and run on the same loop; this avoids issuing a request from
# inside a response callback, which the client does not support.
let authHeaders = @[
  HttpHeader(name: "Authorization", value: "Bearer secret-token"),
  HttpHeader(name: "Cookie", value: "sid=abc123"),
  HttpHeader(name: "Proxy-Authorization", value: "Basic dXNlcg=="),
  HttpHeader(name: "X-Request-Id", value: "keepme-42"),
]

if setupServer():
  echo "--- Redirect auth strip: cross-origin ---"
  httpClient.request(hmGet, "http://" & Host & ":" & $PortA & "/start-redirect",
                     headers = authHeaders, cb = onCrossCb)
  echo "--- Redirect auth strip: same-origin ---"
  httpClient.request(hmGet, "http://" & Host & ":" & $PortA & "/start-same",
                     headers = authHeaders, cb = onSameCb)
  httpClient.run()
else:
  echo "setupServer failed"

check(crossGot, "cross-origin redirect request completed")
if crossGot:
  check(crossStatus == 200, "cross-origin redirect final status 200, got " & $crossStatus)
  check(not (crossBody.contains("Bearer secret-token")), "cross-origin: Authorization stripped")
  check(not (crossBody.contains("sid=abc123")), "cross-origin: Cookie stripped")
  check(not (crossBody.contains("Basic dXNlcg==")), "cross-origin: Proxy-Authorization stripped")
  check(crossBody.contains("keepme-42"), "cross-origin: non-sensitive header kept")

check(sameGot, "same-origin redirect request completed")
if sameGot:
  check(sameStatus == 200, "same-origin redirect final status 200, got " & $sameStatus)
  check(sameBody.contains("Bearer secret-token"), "same-origin: Authorization kept")
  check(sameBody.contains("sid=abc123"), "same-origin: Cookie kept")
  check(sameBody.contains("Basic dXNlcg=="), "same-origin: Proxy-Authorization kept")
  check(sameBody.contains("keepme-42"), "same-origin: non-sensitive header kept")

httpClient.close()

echo ""
echo "Redirect auth strip Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
