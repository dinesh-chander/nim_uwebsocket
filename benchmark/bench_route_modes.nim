## Benchmark route mode overheads:
## - /get           -> app.get (sync handler)
## - /getasync      -> app.getAsync (async handler)

import ../nim_express/src/nim_express

const
  PlainBody = "Hello, World!"

let app = newExpressApp()
app.server.options.minimalHeaderParsing = true

app.get("/get") do (req: Request, res: Response):
  res.text(PlainBody)

app.getAsync("/getasync") do (req: Request, res: Response) {.async.}:
  res.text(PlainBody)

echo "route mode benchmark running on http://localhost:3003"
app.run(3003)
