## HTMX + server-rendered templates example.

import std/[os, strutils, times]
import ../../../nim_express/src/nim_express
import ../../shared/example_support

type
  Card = object
    id: int
    text: string
    createdAt: string

var
  cards: seq[Card] = @[
    Card(id: 1, text: "Server-side templates stay simple", createdAt: $now()),
    Card(id: 2, text: "HTMX keeps interactions lightweight", createdAt: $now())
  ]
  nextCardId = 3

proc parseParamInt(req: Request, key: string): tuple[ok: bool, value: int, err: string] =
  let raw = req.param(key).strip()
  if raw.len == 0:
    return (false, 0, "missing required path parameter: " & key)
  try:
    (true, parseInt(raw), "")
  except ValueError:
    (false, 0, "invalid integer path parameter: " & key)

proc findCardIndex(id: int): int =
  for i, card in cards:
    if card.id == id:
      return i
  -1

proc renderCard(card: Card, tpl: CompiledTemplate): string =
  var locals = newFastMap[string]()
  discard locals.reserve(4)
  discard locals.put("id", $card.id)
  discard locals.put("text", card.text)
  discard locals.put("created_at", card.createdAt)
  renderTemplate(tpl, locals)

proc renderCards(tpl: CompiledTemplate): string =
  var rendered = newStringOfCap(max(64, cards.len * 140))
  for card in cards:
    rendered.add(renderCard(card, tpl))
  rendered

proc main*() =
  let app = newExpressApp()
  let viewsDir = resolveViewsDir("htmx_ssr")
  if viewsDir.len == 0:
    echo "htmx_ssr views not found"
    quit(1)
  app.setViewsDir(viewsDir)

  let cardTplResult = compileTemplateFile(viewsDir / "card.html")
  if not cardTplResult.ok:
    echo "failed to compile card template: ", cardTplResult.error
    quit(1)
  let cardTpl = cardTplResult.compiled

  app.use(bodyParser())
  app.use(htmx())
  app.use(timeout(15_000))

  app.getAsync("/") do (_: Request, res: Response) {.async.}:
    var locals = newFastMap[string]()
    discard locals.reserve(4)
    discard locals.put("title", "HTMX + SSR")
    discard locals.put("subtitle", "Template files render both full pages and partial fragments")
    discard locals.put("cards_html", renderCards(cardTpl))
    res.render("index", locals)

  app.getAsync("/fragments/clock") do (_: Request, res: Response) {.async.}:
    res.contentType("text/html; charset=utf-8")
    res.send("<p><strong>Server clock:</strong> " & $now() & "</p>")

  app.postAsync("/cards") do (req: Request, res: Response) {.async.}:
    let text = req.form("text").strip()
    if text.len == 0:
      res.badRequest("text is required")
      return
    let card = Card(id: nextCardId, text: text, createdAt: $now())
    inc nextCardId
    cards.add(card)
    res.contentType("text/html; charset=utf-8")
    res.send(renderCard(card, cardTpl))

  app.deleteAsync("/cards/:id") do (req: Request, res: Response) {.async.}:
    let idRes = parseParamInt(req, "id")
    if not idRes.ok:
      res.badRequest(idRes.err)
      return
    let idx = findCardIndex(idRes.value)
    if idx < 0:
      res.notFound()
      return
    cards.delete(idx)
    res.status(204).send("")

  app.getAsync("/fragments/slow-status") do (req: Request, res: Response) {.async.}:
    req.onAbort(proc(reason: RequestCancelReason) =
      echo "[htmx_ssr_app] slow-status aborted: ", $reason
    )
    for _ in 0 ..< 30:
      if req.aborted():
        return
      await sleepAsync(20)
    if req.aborted():
      return
    res.contentType("text/html; charset=utf-8")
    res.send(
      "<p>Slow fragment finished. Remaining timeout: " &
      $requestTimeoutRemainingMs(req) & "ms</p>"
    )

  let port = parsePort(3000)
  app.listen(port) do (ok: bool):
    if ok:
      echo "htmx_ssr_app listening on http://localhost:", port
    else:
      echo "failed to start htmx_ssr_app"
      quit(1)
