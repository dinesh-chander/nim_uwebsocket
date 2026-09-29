## Security-oriented middleware example.

import std/[json, strutils]
import ../../../nim_express/src/nim_express
import ../../shared/example_support

proc nextVisitCount(req: Request): int =
  var current = 0
  try:
    current = parseInt(sessionGet(req, "visits", "0"))
  except ValueError:
    current = 0
  inc current
  sessionSet(req, "visits", $current)
  current

proc main*() =
  let app = newExpressApp()
  let viewsDir = resolveViewsDir("security")
  if viewsDir.len == 0:
    echo "security views not found"
    quit(1)
  app.setViewsDir(viewsDir)

  var sess = defaultSessionOptions()
  sess.saveUninitialized = true
  sess.ttlSeconds = 3600
  sess.httpOnlyCookie = true
  sess.sameSite = "Lax"

  var csp = defaultHelmetOptions()
  csp.contentSecurityPolicy = true
  csp.contentSecurityPolicyNonce = true
  csp.contentSecurityPolicyValue = "default-src 'self'; script-src 'self' 'nonce-{nonce}'"

  app.use(requestId())
  app.use(rateLimit(maxRequests = 60, windowMs = 60_000, trustProxy = false))
  app.use(cookieParser())
  app.use(bodyParser())
  app.use(session(sess))
  app.use(csrf())
  app.use(helmet(csp))
  app.use(timeout(12_000))

  app.getAsync("/") do (req: Request, res: Response) {.async.}:
    let visits = nextVisitCount(req)
    var locals = newFastMap[string]()
    discard locals.reserve(5)
    discard locals.put("title", "Security Middleware Example")
    discard locals.put("subtitle", "Helmet + rate limiting + session + CSRF")
    discard locals.put("visit_count", $visits)
    discard locals.put("csrf_token", csrfToken(req))
    res.render("index", locals)

  app.postAsync("/profile") do (req: Request, res: Response) {.async.}:
    let displayName = req.form("display_name").strip()
    if displayName.len == 0:
      res.badRequest("display_name is required")
      return
    sessionSet(req, "display_name", displayName)
    res.json(%*{
      "ok": true,
      "display_name": displayName,
      "csrf_validated": true
    })

  app.getAsync("/api/session") do (req: Request, res: Response) {.async.}:
    res.json(%*{
      "visits": sessionGet(req, "visits", "0"),
      "display_name": sessionGet(req, "display_name", ""),
      "request_id": req.local("request_id")
    })

  app.postAsync("/session/clear") do (req: Request, res: Response) {.async.}:
    destroySession(req)
    res.status(202).json(%*{"cleared": true})

  app.getAsync("/api/audit") do (req: Request, res: Response) {.async.}:
    req.onAbort(proc(reason: RequestCancelReason) =
      echo "[security_hardening_app] audit aborted: ", $reason
    )
    for _ in 0 ..< 30:
      if req.aborted():
        return
      await sleepAsync(20)
    if req.aborted():
      return
    res.json(%*{
      "ok": true,
      "timeoutRemainingMs": requestTimeoutRemainingMs(req),
      "headersApplied": [
        "x-content-type-options",
        "x-frame-options",
        "content-security-policy"
      ]
    })

  let port = parsePort(3000)
  app.listen(port) do (ok: bool):
    if ok:
      echo "security_hardening_app listening on http://localhost:", port
    else:
      echo "failed to start security_hardening_app"
      quit(1)
