import std/[json, os, strutils, atomics]
import ../nim_express/src/nim_express

const IndexHtml = staticRead("views/index.html")
let TemplateRenderMode = getEnv("NIM_EXPRESS_TEMPLATE_RENDER_MODE", "pairs").toLowerAscii()
var RequestNumberCounter: Atomic[uint64]

proc requestNumberValue(_: Request): string {.inline.} =
  var x = RequestNumberCounter.fetchAdd(1'u64, moRelaxed) + 1'u64
  x += 0x9E3779B97F4A7C15'u64
  x = (x xor (x shr 30)) * 0xBF58476D1CE4E5B9'u64
  x = (x xor (x shr 27)) * 0x94D049BB133111EB'u64
  x = x xor (x shr 31)
  $(x mod 1_000_000_000'u64)

proc main() =
  let app = newExpressApp()
  app.embedView("index", IndexHtml)

  app.use(corsSync())
  app.use(bodyParserSync())

  # Home route
  app.get("/") do (req: Request, res: Response):
    let requestNumber = requestNumberValue(req)
    if TemplateRenderMode == "locals":
      req.locals["title"] = "nim_express"
      req.locals["heading"] = "Welcome to nim_express!"
      req.locals["description"] = "Express-like framework for Nim."
      req.locals["request_number"] = requestNumber
      res.render("index", req.locals)
    else:
      res.render("index", {
        "title": "nim_express",
        "heading": "Welcome to nim_express!",
        "description": "Express-like framework for Nim.",
        "request_number": requestNumber
      })

  # API routes
  app.get("/api/users") do (req: Request, res: Response):
    res.json(%*{
      "users": [
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"},
        {"id": 3, "name": "Charlie"}
      ]
    })

  app.get("/api/users/:id") do (req: Request, res: Response):
    let userId = req.params["id"]
    res.json(%*{
      "id": userId,
      "name": "User " & userId,
      "email": "user" & userId & "@example.com"
    })

  app.post("/api/users") do (req: Request, res: Response):
    let body = req.getJsonBody()
    res.status(201).json(%*{
      "message": "User created",
      "data": body
    })

  app.put("/api/users/:id") do (req: Request, res: Response):
    let userId = req.params["id"]
    let body = req.getJsonBody()
    res.json(%*{
      "message": "User updated",
      "id": userId,
      "data": body
    })

  app.delete("/api/users/:id") do (req: Request, res: Response):
    let userId = req.params["id"]
    res.json(%*{
      "message": "User deleted",
      "id": userId
    })

  # Query params example
  app.get("/search") do (req: Request, res: Response):
    let query = req.queryParam("q", "")
    let page = req.queryParam("page", "1")
    res.json(%*{
      "query": query,
      "page": page,
      "results": []
    })

  # Error example
  app.get("/error") do (req: Request, res: Response):
    res.status(500).json(%*{"error": "Something went wrong"})

  # Start server
  echo "Starting nim_express server..."
  app.listen(3000) do (success: bool):
    if success:
      echo "Server running on http://localhost:3000"
    else:
      echo "Failed to start server!"
      quit(1)

when isMainModule:
  main()
