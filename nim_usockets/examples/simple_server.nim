## Simple HTTP server example using nim_usockets
##
## Run with:
##   nim c -r --passL:"-L../usockets -lusockets" simple_server.nim

import std/strutils
import ../src/nim_usockets

proc main() =
  # Create a new HTTP server (non-SSL)
  let server = newHttpServer(NoSsl)

  # Set up request handler
  server.handle proc(req: HttpRequest, res: HttpResponse) =
    echo "Request: ", req.methodKind, " ", req.path

    case req.path
    of "/":
      res.html("""
<!DOCTYPE html>
<html>
<head>
  <title>nim_usockets</title>
</head>
<body>
  <h1>Hello from nim_usockets!</h1>
  <p>A high-performance HTTP server for Nim.</p>
  <ul>
    <li><a href="/api/status">API Status</a></li>
    <li><a href="/api/echo?message=hello">Echo API</a></li>
  </ul>
</body>
</html>
""")

    of "/api/status":
      res.json("""{"status": "ok", "server": "nim_usockets"}""")

    elif req.path.startsWith("/api/echo"):
      let message = req.query.getOrDefault("message", "no message")
      res.json("{\"echo\": \"" & message & "\"}")

    else:
      res.setStatus(Http404)
      res.setHeader("content-type", "text/plain")
      res.`end`("404 Not Found: " & req.path)

  # Start listening
  server.listen("0.0.0.0", 3000) do(success: bool):
    if success:
      echo "Server running at http://localhost:3000"
      echo "Press Ctrl+C to stop"
    else:
      echo "Failed to start server!"
      quit(1)

  # Run the event loop (blocking)
  server.run()

when isMainModule:
  main()
