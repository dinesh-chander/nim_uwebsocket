import std/[strutils, json, asyncdispatch]
import nim_fasthttpclient/types
import nim_fasthttpclient/client as fastclient
import nim_usockets/usockets
import nim_express
import nim_express/app as expressApp

var passed = 0
var failed = 0

template check(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failed += 1
    echo "FAIL: ", msg

const TestPort = 3300
const UpstreamPort = 3301

var upstreamListenSocket: UsListenSocketPtr
var upstreamCtx: UsSocketContextPtr
var downstreamClient: HttpClient

proc onUpstreamOpen(s: UsSocketPtr, isClient: cint, ip: cstring, ipLength: cint): UsSocketPtr {.cdecl.} = s

proc onUpstreamData(s: UsSocketPtr, data: cstring, length: cint): UsSocketPtr {.cdecl.} =
  let body = """{"upstream":"ok"}"""
  var resp = "HTTP/1.1 200 OK\r\nContent-Length: " & $body.len & "\r\nConnection: close\r\n\r\n" & body
  discard us_socket_write(0, s, cstring(resp), cint(resp.len), 0)
  us_socket_shutdown(0, s)
  s

proc onUpstreamWritable(s: UsSocketPtr): UsSocketPtr {.cdecl.} = s
proc onUpstreamClose(s: UsSocketPtr, code: cint, reason: pointer): UsSocketPtr {.cdecl.} = s

proc onUpstreamEnd(s: UsSocketPtr): UsSocketPtr {.cdecl.} =
  discard us_socket_close(0, s, 0, nil)
  s

proc onUpstreamConnectError(s: UsSocketPtr, code: cint): UsSocketPtr {.cdecl.} = s

var gotHealthResponse = false
var healthStatus = 0
var healthBody = ""

var gotUpstreamResponse = false
var upstreamStatus = 0
var upstreamBody = ""
var upstreamHandlerError = ""

var verificationClient: HttpClient
var app: ExpressApp

proc finishTests() {.gcsafe.} =
  {.cast(gcsafe).}:
    if app != nil and app.server != nil:
      app.server.`defer`(proc() =
        if upstreamListenSocket != nil:
          us_listen_socket_close(0, upstreamListenSocket)
          upstreamListenSocket = nil
        fastclient.close(downstreamClient)
        fastclient.close(verificationClient)
        expressApp.close(app)
      )

proc onUpstreamResponseCb(resp: types.HttpResponse, err: string) =
  {.cast(gcsafe).}:
    gotUpstreamResponse = true
    upstreamStatus = resp.statusCode
    upstreamBody = resp.body
    finishTests()

proc onHealthResponseCb(resp: types.HttpResponse, err: string) =
  {.cast(gcsafe).}:
    gotHealthResponse = true
    healthStatus = resp.statusCode
    healthBody = resp.body
    fastclient.get(verificationClient, "http://127.0.0.1:" & $TestPort & "/call-upstream", onUpstreamResponseCb)

app = newExpressApp()

app.get("/health") do (req: Request, res: Response):
  res.json(%*{"status": "ok"})

app.getAsync("/call-upstream") do (req: Request, res: Response) {.async.}:
  let capturedRes = res
  let fut = newFuture[void]("call-upstream")
  fastclient.get(downstreamClient, "http://127.0.0.1:" & $UpstreamPort & "/data",
    proc(resp: types.HttpResponse, err: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        if err.len > 0:
          upstreamHandlerError = err
          capturedRes.status(502).json(%*{"error": err})
        else:
          capturedRes.json(%*{"upstream_status": resp.statusCode, "upstream_body": resp.body})
        fut.complete()
  )
  await fut

app.listen(TestPort) do (success: bool):
  if not success:
    echo "FAIL: Could not start express server on port ", TestPort
    quit(1)

  let loop = expressApp.getEventLoop(app)
  check(loop != nil, "getEventLoop returns non-nil loop")

  downstreamClient = fastclient.newHttpClient()
  fastclient.initClientWithLoop(downstreamClient, loop)
  check(downstreamClient.initialized, "client initialized with shared loop")
  check(not downstreamClient.ownsLoop, "client does not own the loop")

  let options = defaultSocketContextOptions()
  upstreamCtx = us_create_socket_context(0, loop, 0, options)
  us_socket_context_on_open(0, upstreamCtx, onUpstreamOpen)
  us_socket_context_on_data(0, upstreamCtx, onUpstreamData)
  us_socket_context_on_writable(0, upstreamCtx, onUpstreamWritable)
  us_socket_context_on_close(0, upstreamCtx, onUpstreamClose)
  us_socket_context_on_end(0, upstreamCtx, onUpstreamEnd)
  us_socket_context_on_connect_error(0, upstreamCtx, onUpstreamConnectError)
  upstreamListenSocket = us_socket_context_listen(0, upstreamCtx, "127.0.0.1", cint(UpstreamPort), 0, 0)

  verificationClient = fastclient.newHttpClient()
  fastclient.initClientWithLoop(verificationClient, loop)

  echo "--- Test: health check via shared loop ---"
  fastclient.get(verificationClient, "http://127.0.0.1:" & $TestPort & "/health", onHealthResponseCb)

echo "--- Results ---"

check(gotHealthResponse, "health check received response")
if gotHealthResponse:
  check(healthStatus == 200, "health check status 200, got " & $healthStatus)
  check("ok" in healthBody, "health check body contains ok")
echo "  Health check via shared loop: ", (if gotHealthResponse and healthStatus == 200: "OK" else: "FAIL")

check(gotUpstreamResponse, "upstream call received response")
if gotUpstreamResponse:
  check(upstreamStatus == 200, "upstream call status 200, got " & $upstreamStatus)
  check("upstream" in upstreamBody, "upstream call body contains upstream data")
  if upstreamStatus != 200:
    echo "  Upstream handler error: ", upstreamHandlerError
    echo "  Upstream response body: ", upstreamBody
echo "  Upstream call via handler: ", (if gotUpstreamResponse and upstreamStatus == 200: "OK" else: "FAIL")

echo ""
echo "Shared Loop Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
