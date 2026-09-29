import std/[atomics, os, strutils]
import ../nim_express/src/nim_express

const IndexHtml = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{ title }}</title>
</head>
<body>
  <main>
    <h1>{{ heading }}</h1>
    <p>{{ description }}</p>
    <p data-request-number="{{ requestNumber }}">request={{ requestNumber }}</p>
  </main>
</body>
</html>
"""

var requestNumberCounter: Atomic[uint64]

proc requestNumberValue(): string {.inline.} =
  var x = requestNumberCounter.fetchAdd(1'u64, moRelaxed) + 1'u64
  x += 0x9E3779B97F4A7C15'u64
  x = (x xor (x shr 30)) * 0xBF58476D1CE4E5B9'u64
  x = (x xor (x shr 27)) * 0x94D049BB133111EB'u64
  x = x xor (x shr 31)
  $(x mod 1_000_000_000'u64)

proc renderPairs(requestNumber: string): array[4, (string, string)] =
  [
    ("title", "nim_express"),
    ("heading", "Welcome to nim_express!"),
    ("description", "Express-like framework for Nim."),
    ("requestNumber", requestNumber)
  ]

let app = newExpressApp()
app.embedView("index", IndexHtml)

app.getAsync("/health") do (_: Request, res: Response) {.async.}:
  res.send("ok")

app.getAsync("/render-sync") do (_: Request, res: Response) {.async.}:
  res.render("index", renderPairs(requestNumberValue()))

app.getAsync("/render-offload") do (_: Request, res: Response) {.async.}:
  await res.renderOffload("index", renderPairs(requestNumberValue()))

let port = parseInt(getEnv("PORT", "3000"))
echo "render_offload_app listening on http://127.0.0.1:", port
app.run(port)
