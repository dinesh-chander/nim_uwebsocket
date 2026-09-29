import nim_express

let app = newExpressApp()
app.server.options.minimalHeaderParsing = true

app.get("/") do (req: Request, res: Response):
  res.json("{\"message\":\"Hello, World!\"}")

app.get("/plaintext") do (req: Request, res: Response):
  res.text("Hello, World!")

echo "H2 benchmark server running on http://localhost:3200"
app.run(3200)
