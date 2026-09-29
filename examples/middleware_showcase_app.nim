## Middleware showcase app for nim_express production middlewares.

import std/[json, os, strutils]
import ../nim_express/src/nim_express

proc resolveExistingPath(candidates: openArray[string]): string =
  for candidate in candidates:
    if candidate.len == 0:
      continue
    if dirExists(candidate):
      return candidate
  ""

proc main() =
  let app = newExpressApp()

  let staticRoot = resolveExistingPath([
    "examples/public",
    "public"
  ])

  var helm = defaultHelmetOptions()
  helm.contentSecurityPolicy = true
  helm.contentSecurityPolicyNonce = true
  helm.contentSecurityPolicyValue = "default-src 'self'; script-src 'nonce-{nonce}'"

  var sess = defaultSessionOptions()
  sess.saveUninitialized = true

  app.use(logger(llInfo))
  app.use(requestId())
  app.use(cookieParser())
  app.use(helmet(helm))
  installCompressionPolicy(app, defaultCompressionPolicyOptions())
  app.use(compression())
  if staticRoot.len > 0:
    app.use(serveStatic(staticRoot, "/public"))
  app.use(json())
  app.use(urlencoded())
  app.use(text())
  app.use(raw())
  app.use(multipart())
  app.use(session(sess))
  app.use(csrf())
  app.use(etag())
  methodOverride(app)

  app.get("/") do (req: Request, res: Response):
    res.json(%*{
      "name": "middleware_showcase_app",
      "csrfToken": req.local("csrf_token", ""),
      "routes": [
        "GET /etag-demo",
        "POST /echo/json",
        "POST /echo/form",
        "POST /echo/text",
        "POST /echo/raw",
        "POST /upload",
        "POST /resource/:id + X-HTTP-Method-Override: PATCH",
        "GET /session",
        "POST /session/clear",
        "GET /public/hello.txt"
      ]
    })

  app.get("/etag-demo") do (req: Request, res: Response):
    res.text("etag-demo-v1")

  app.post("/echo/json") do (req: Request, res: Response):
    let body = req.getJsonBody()
    if body == nil:
      res.badRequest("Invalid JSON")
      return
    res.json(%*{"ok": true, "body": body})

  app.post("/echo/form") do (req: Request, res: Response):
    res.json(%*{
      "ok": true,
      "name": req.form("name", ""),
      "value": req.form("value", "")
    })

  app.post("/echo/text") do (req: Request, res: Response):
    res.text("text=" & req.bodyText(""))

  app.post("/echo/raw") do (req: Request, res: Response):
    let payload = req.bodyRaw("")
    res.json(%*{
      "ok": true,
      "size": payload.len
    })

  app.post("/upload") do (req: Request, res: Response):
    res.json(%*{
      "ok": true,
      "title": req.form("title", ""),
      "fileName": req.local("file_upload_name", ""),
      "fileSize": req.local("file_upload_size", ""),
      "filePath": req.local("file_upload_path", "")
    })

  app.patch("/resource/:id") do (req: Request, res: Response):
    res.json(%*{
      "ok": true,
      "method": "PATCH",
      "id": req.param("id")
    })

  app.get("/session") do (req: Request, res: Response):
    var count = 0
    try:
      count = parseInt(sessionGet(req, "count", "0"))
    except ValueError:
      count = 0
    inc count
    sessionSet(req, "count", $count)
    res.json(%*{
      "ok": true,
      "count": count
    })

  app.post("/session/clear") do (req: Request, res: Response):
    destroySession(req)
    res.json(%*{"ok": true, "cleared": true})

  let port = parseInt(getEnv("PORT", "3000"))
  app.listen(port) do (success: bool):
    if success:
      echo "middleware_showcase_app listening on http://localhost:", port
    else:
      echo "failed to start middleware_showcase_app"
      quit(1)

when isMainModule:
  main()
