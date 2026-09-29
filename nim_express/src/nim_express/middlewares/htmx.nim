## HTMX helper middleware
## Detects HTMX requests and extracts common HTMX headers into request locals.
## Local values sourced from HTMX headers are untrusted user input; escape
## them before reflecting into HTML output.

import std/asyncdispatch
import common

## Detects HTMX requests, extracts common HX headers into request locals, and adds Vary cache hints.
proc htmx*(): AsyncMiddleware {.inline.} =
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let boosted =
      if req != nil: req.get("hx-boosted")
      else: ""
    if req != nil and req.isHtmx():
      req.locals["htmx"] = "true"
      let target = req.get("hx-target")
      let trigger = req.get("hx-trigger")
      let triggerName = req.get("hx-trigger-name")
      let currentUrl = req.get("hx-current-url")
      let prompt = req.get("hx-prompt")
      let historyRestore = req.get("hx-history-restore-request")
      if target.len > 0:
        req.locals["htmx-target"] = target
      if trigger.len > 0:
        req.locals["htmx-trigger"] = trigger
      if triggerName.len > 0:
        req.locals["htmx-trigger-name"] = triggerName
      if currentUrl.len > 0:
        req.locals["htmx-current-url"] = currentUrl
      if prompt.len > 0:
        req.locals["htmx-prompt"] = prompt
      if boosted.len > 0:
        req.locals["htmx-boosted"] = boosted
      if historyRestore.len > 0:
        req.locals["htmx-history-restore-request"] = historyRestore
    # Vary on ALL responses so caches differentiate HTMX vs full-page
    res.append("Vary", "HX-Request")
    if boosted.len > 0:
      res.append("Vary", "HX-Boosted")
    await next()
