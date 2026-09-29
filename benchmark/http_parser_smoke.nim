import ../nim_usockets/src/nim_usockets

proc main() =
  let server = newHttpServer(NoSsl)

  server.handle proc(req: HttpRequest, res: HttpResponse) =
    if req.methodKind == hmGet and req.path == "/ping":
      res.setHeader("content-type", "text/plain")
      res.`end`("pong")
    elif req.methodKind == hmPost and req.path == "/echo":
      res.setHeader("content-type", "text/plain")
      res.`end`(req.body)
    else:
      res.setStatus(Http404)
      res.setHeader("content-type", "text/plain")
      res.`end`("not-found")

  server.listen("127.0.0.1", 3012) do(ok: bool):
    if ok:
      echo "listen-ok"
    else:
      echo "listen-fail"
      quit(1)

  server.run()

when isMainModule:
  main()
