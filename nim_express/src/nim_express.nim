## nim_express - High-Performance Web Framework for Nim
##
## Express.js-inspired framework built on uWebSockets for blazing fast HTTP/WebSocket.
## Uses async/await for non-blocking file I/O, HTTP client, and other operations.
##
## ## Quick Start
##
## ```nim
## import nim_express
##
## let app = newExpressApp()
##
## # Middleware
## app.use(logger())
## app.use(cors())
## app.use(bodyParser())
## app.use(helmet())
##
## # Routes with async handlers
## app.getAsync("/") do (req: Request, res: Response) {.async.}:
##   res.html("<h1>Hello World!</h1>")
##
## app.getAsync("/api/users/:id") do (req: Request, res: Response) {.async.}:
##   let id = req.param("id")
##   res.json(%*{"id": id, "name": "User " & id})
##
## # Async file I/O in handlers
## app.getAsync("/file") do (req: Request, res: Response) {.async.}:
##   let content = await readFileAsync("/etc/hosts")
##   res.text(content)
##
## # WebSocket support
## app.ws proc(ws: WebSocket, message: string, isBinary: bool) =
##   ws.sendText("Echo: " & message)
##
## app.onWsOpen proc(ws: WebSocket) =
##   echo "Client connected"
##
## # Start server
## app.run(3000)
## ```
##
## ## Modules
##
## * ``nim_express/app`` -- app lifecycle, routing registration, `run`/`runCluster`/`runThreaded`, WebSocket endpoints.
## * ``nim_express/request`` -- request helpers: headers, params, query, body, cookies, locals, content negotiation.
## * ``nim_express/response`` -- response helpers: json, html, text, file, SSE, compression, streaming.
## * ``nim_express/types`` -- core types: ``AppConfig``, ``Router``, ``Request``, ``Response``, lifecycle and pooling.
## * ``nim_express/middlewares`` -- middleware hub re-exporting all built-in middlewares.
## * ``nim_express/config`` -- environment-driven configuration loading.
## * ``nim_express/windowing`` -- range/window pagination helpers for item-based APIs.
## * ``nim_express/scaffold`` -- project scaffolding helpers.
##
## ## Built-in Middlewares
##
## * Body parsing: ``bodyParser`` · ``json`` · ``urlencoded`` · ``multipart`` · ``raw`` · ``bodyLimit`` · ``cookieParser``
## * Security: ``cors`` · ``helmet`` · ``csrf`` · ``rateLimit`` · ``ipFilter`` · ``methodOverride`` · ``circuitBreakerMiddleware`` · ``concurrencyGuard``
## * Output: ``compression`` · ``etag`` · ``outputCache`` · ``mergeSlashes`` · ``normalizePath`` · ``text`` · ``xml``
## * Sessions/state: ``session`` · ``state`` · ``gracefulShutdown``
## * Files: ``serveStatic`` · ``download``
## * Observability: ``logger`` · ``jsonLogger`` · ``errorHandler`` · ``panicRecovery`` · ``requestId`` · ``serverTiming`` · ``responseTime`` · ``prometheusMetrics`` · ``openTelemetry`` · ``health``
## * Misc: ``timeout`` · ``proxy`` · ``fastProxy`` · ``document`` · ``openapi`` · ``htmx`` · ``backpressure`` · ``reset``

# Core modules
import nim_express/types
import nim_express/request
import nim_express/response
import nim_express/app
import nim_express/middlewares
import nim_express/json_utils
import nim_express/offload
import nim_express/paged_buffer
import nim_express/fast_hash
import nim_express/config
import nim_express/windowing
import nim_express/scaffold

# Export everything
export types
export request
export response
export app
export middlewares
export json_utils
export offload
export paged_buffer
export fast_hash
export config
export windowing
export scaffold

# Re-export common modules
import std/[json, asyncdispatch]
import jsony
export json, asyncdispatch, jsony
