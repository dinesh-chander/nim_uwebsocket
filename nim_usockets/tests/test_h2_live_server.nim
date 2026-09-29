import ../src/nim_usockets/http

proc main() =
  let server = newHttpServer()

  server.handle proc(req: HttpRequest, res: HttpResponse) =
    stderr.writeLine "[H2-HANDLER] got request: method=" & $req.methodKind & " path=" & req.path
    res.setStatus(Http200)
    res.setHeader("content-type", "text/plain")
    res.`end`("hello h2spec")
    stderr.writeLine "[H2-HANDLER] response sent"

  server.onError proc(msg: string) =
    stderr.writeLine "[H2-ERROR] " & msg

  server.onPanic proc(msg: string) =
    stderr.writeLine "[H2-PANIC] " & msg

  echo "H2 live test server starting on port 8443..."
  server.listen("0.0.0.0", 8443) do(success: bool):
    if success:
      echo "H2 test server listening on port 8443"
    else:
      echo "FATAL: Failed to bind port 8443"
      quit(1)

  server.run()

when isMainModule:
  main()
