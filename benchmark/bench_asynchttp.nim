## Benchmark: Nim asynchttpserver (stdlib)
## Endpoints: /json, /plaintext
## JSON is constructed dynamically each request

import std/[asynchttpserver, asyncdispatch, json, times, random]

randomize()

proc main() {.async.} =
  var server = newAsyncHttpServer()

  proc handler(req: Request) {.async.} =
    case req.url.path
    of "/json":
      # Construct JSON dynamically each request
      let timestamp = getTime().toUnix()
      let randomId = rand(1..999999)
      let response = %*{
        "message": "Hello, World!",
        "timestamp": timestamp,
        "id": randomId,
        "success": true
      }
      let headers = newHttpHeaders([("Content-Type", "application/json")])
      await req.respond(Http200, $response, headers)
    of "/plaintext":
      let headers = newHttpHeaders([("Content-Type", "text/plain")])
      await req.respond(Http200, "Hello, World!", headers)
    else:
      await req.respond(Http404, "Not Found")

  echo "asynchttpserver running on http://localhost:3001"
  server.listen(Port(3001))

  while true:
    if server.shouldAcceptRequest():
      await server.acceptRequest(handler)
    else:
      await sleepAsync(500)

waitFor main()
