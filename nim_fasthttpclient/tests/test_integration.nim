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

const TestPort = 9877
const TestHost = "127.0.0.1"
const ResponseBody = """{"status":"ok"}"""

var serverListenSocket: UsListenSocketPtr
var httpClient: HttpClient

var getGotResponse = false
var getStatus = 0
var getBody = ""
var getErr = ""

var postGotResponse = false
var postStatus = 0
var postBody = ""
var postErr = ""

var errGotCallback = false
var errErrMsg = ""

var phase = 0

proc onServerOpen(s: UsSocketPtr, isClient: cint, ip: cstring, ipLength: cint): UsSocketPtr {.cdecl.} = s

proc onServerData(s: UsSocketPtr, data: cstring, length: cint): UsSocketPtr {.cdecl.} =
  var resp = "HTTP/1.1 200 OK\r\nContent-Length: " & $ResponseBody.len & "\r\nConnection: close\r\n\r\n" & ResponseBody
  discard us_socket_write(0, s, cstring(resp), cint(resp.len), 0)
  us_socket_shutdown(0, s)
  s

proc onServerWritable(s: UsSocketPtr): UsSocketPtr {.cdecl.} = s
proc onServerClose(s: UsSocketPtr, code: cint, reason: pointer): UsSocketPtr {.cdecl.} = s

proc onServerEnd(s: UsSocketPtr): UsSocketPtr {.cdecl.} =
  discard us_socket_close(0, s, 0, nil)
  s

proc onServerConnectError(s: UsSocketPtr, code: cint): UsSocketPtr {.cdecl.} = s

var serverCtx: UsSocketContextPtr

proc setupServer() =
  let options = defaultSocketContextOptions()
  serverCtx = us_create_socket_context(0, httpClient.loop, 0, options)
  us_socket_context_on_open(0, serverCtx, onServerOpen)
  us_socket_context_on_data(0, serverCtx, onServerData)
  us_socket_context_on_writable(0, serverCtx, onServerWritable)
  us_socket_context_on_close(0, serverCtx, onServerClose)
  us_socket_context_on_end(0, serverCtx, onServerEnd)
  us_socket_context_on_connect_error(0, serverCtx, onServerConnectError)
  serverListenSocket = us_socket_context_listen(0, serverCtx, TestHost, cint(TestPort), 0, 0)

proc teardownServer() =
  if serverListenSocket != nil:
    us_listen_socket_close(0, serverListenSocket)
    serverListenSocket = nil

proc startNextPhase() {.gcsafe.}

proc onGetCb(resp: HttpResponse, err: string) =
  {.cast(gcsafe).}:
    getGotResponse = true
    getStatus = resp.statusCode
    getBody = resp.body
    getErr = err
    teardownServer()
    phase = 1
    startNextPhase()

proc onPostCb(resp: HttpResponse, err: string) =
  {.cast(gcsafe).}:
    postGotResponse = true
    postStatus = resp.statusCode
    postBody = resp.body
    postErr = err
    teardownServer()
    phase = 2
    startNextPhase()

proc onErrCb(resp: HttpResponse, err: string) =
  {.cast(gcsafe).}:
    errGotCallback = true
    errErrMsg = err
    phase = 3
    stopLoop(httpClient)

proc startNextPhase() =
  {.cast(gcsafe).}:
    case phase
    of 0:
      echo "--- Integration: HTTP GET ---"
      setupServer()
      httpClient.get("http://" & TestHost & ":" & $TestPort & "/test", onGetCb)
    of 1:
      echo "--- Integration: HTTP POST ---"
      setupServer()
      httpClient.post("http://" & TestHost & ":" & $TestPort & "/data", """{"key":"val"}""", onPostCb)
    of 2:
      echo "--- Integration: Connect Error ---"
      httpClient.get("http://" & TestHost & ":19999/nothing", onErrCb)
    else:
      stopLoop(httpClient)

httpClient = newHttpClient()
initClient(httpClient, ssl = false)

phase = 0
startNextPhase()

httpClient.run()

check(getGotResponse, "GET received response")
if getGotResponse:
  check(getStatus == 200, "GET status 200, got " & $getStatus)
  check(getBody == ResponseBody, "GET body matches")
  check(getErr.len == 0, "GET no error")
echo "  HTTP GET: ", (if getGotResponse and getStatus == 200: "OK" else: "FAIL")

check(postGotResponse, "POST received response")
if postGotResponse:
  check(postStatus == 200, "POST status 200, got " & $postStatus)
  check(postBody == ResponseBody, "POST body matches")
  check(postErr.len == 0, "POST no error")
echo "  HTTP POST: ", (if postGotResponse and postStatus == 200: "OK" else: "FAIL")

check(errGotCallback, "connect error callback fired")
if errGotCallback:
  check(errErrMsg.len > 0, "connect error has error message")
echo "  Connect Error: ", (if errGotCallback and errErrMsg.len > 0: "OK" else: "FAIL")

httpClient.close()

echo ""
echo "Integration Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
