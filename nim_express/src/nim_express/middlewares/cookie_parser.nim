## Cookie parser middleware
##
## Eagerly parses the Cookie header into req.cookies on every request that
## carries one, so downstream middleware/handlers can read req.cookies without
## triggering the lazy parser. This is an opt-in cost: register it per-route (or
## globally) only when handlers read more than one or two cookies per request;
## for the single-cookie case the lazy req.getCookie(name) path is cheaper.
##
## The parse is bounded (see parseCookieHeaderBounded) and rejects the whole
## header on overflow or on control bytes in a name/value (header-injection
## defense-in-depth). On rejection the cookies are cleared and the
## cookieParseRejected flag is raised.
##
## Note: duplicate Cookie headers (which RFC 6265 section 5.4 permits) are
## combined with "; " during header population, so cookie pairs from every
## Cookie header reach req.cookies.

import common

## Parse cookies into req.cookies so downstream middleware/handlers can use
## req.cookies directly. Gracefully handles malformed cookie headers without
## crashing.
proc cookieParser*(): AsyncMiddleware =
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    if req == nil:
      await next()
      return
    let cookieView = req.getView("cookie")
    if cookieView.len > 0:
      try:
        if not parseCookieHeaderBounded(cookieView, req.cookies):
          req.cookies.clear()
          req.locals[CookieParseRejectedKey] = "1"
      except CatchableError:
        req.cookies.clear()
        req.locals[CookieParseRejectedKey] = "1"
    markCookiesParsed(req)
    await next()
