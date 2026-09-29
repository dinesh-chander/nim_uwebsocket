import nim_usockets/usockets

when defined(macosx):
  proc CFRunLoopRun() {.importc, header: "<CoreFoundation/CoreFoundation.h>".}

const
  Port = 3160
  Response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\nConnection: keep-alive\r\n\r\n{\"message\":\"Hello, World!\"}"
  ResponseLen = Response.len
  Delimiter = "\r\n\r\n"

proc countRequests(data: cstring, length: cint): int {.inline.} =
  var count = 0
  var i = 0
  let dataLen = int(length)
  while i <= dataLen - 4:
    if cast[ptr UncheckedArray[char]](data)[i] == '\r' and
       cast[ptr UncheckedArray[char]](data)[i+1] == '\n' and
       cast[ptr UncheckedArray[char]](data)[i+2] == '\r' and
       cast[ptr UncheckedArray[char]](data)[i+3] == '\n':
      count += 1
      i += 4
    else:
      i += 1
  count

var batchBuf: string

proc onOpen(s: UsSocketPtr, isClient: cint, ip: cstring, ipLength: cint): UsSocketPtr {.cdecl.} = s

proc onData(s: UsSocketPtr, data: cstring, length: cint): UsSocketPtr {.cdecl.} =
  let n = countRequests(data, length)
  if n == 1:
    discard us_socket_write(0, s, cstring(Response), cint(ResponseLen), 0)
  elif n > 1:
    batchBuf.setLen(0)
    for i in 0 ..< n:
      batchBuf.add Response
    discard us_socket_write(0, s, cstring(batchBuf), cint(batchBuf.len), 0)
  s

proc onWritable(s: UsSocketPtr): UsSocketPtr {.cdecl.} = s
proc onClose(s: UsSocketPtr, code: cint, reason: pointer): UsSocketPtr {.cdecl.} = s

proc onEnd(s: UsSocketPtr): UsSocketPtr {.cdecl.} =
  discard us_socket_close(0, s, 0, nil)
  s

proc onConnErr(s: UsSocketPtr, code: cint): UsSocketPtr {.cdecl.} = s
proc loopWakeup(loop: UsLoopPtr) {.cdecl.} = discard
proc loopPre(loop: UsLoopPtr) {.cdecl.} = discard
proc loopPost(loop: UsLoopPtr) {.cdecl.} = discard

batchBuf = newStringOfCap(ResponseLen * 64)

let loop = us_create_loop(nil, loopWakeup, loopPre, loopPost, 0)
let options = defaultSocketContextOptions()
let ctx = us_create_socket_context(0, loop, 0, options)

us_socket_context_on_open(0, ctx, onOpen)
us_socket_context_on_data(0, ctx, onData)
us_socket_context_on_writable(0, ctx, onWritable)
us_socket_context_on_close(0, ctx, onClose)
us_socket_context_on_end(0, ctx, onEnd)
us_socket_context_on_connect_error(0, ctx, onConnErr)

let listenSocket = us_socket_context_listen(0, ctx, "0.0.0.0", cint(Port), 0, 0)
if listenSocket == nil:
  echo "Failed to listen on port ", Port
  quit(1)

echo "Benchmark server listening on port ", Port
us_loop_run(loop)
