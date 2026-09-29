## nim_usockets - High performance HTTP and WebSocket server for Nim
##
## This package provides Nim bindings for uWebSockets/uSockets, offering
## extremely fast networking capabilities for building web servers.
##
## ## Quick Start
##
## ```nim
## import nim_usockets
##
## let server = newHttpServer()
##
## server.handle proc(req: HttpRequest, res: HttpResponse) =
##   case req.path
##   of "/":
##     res.html("<h1>Hello from nim_usockets!</h1>")
##   of "/api":
##     res.json("""{"status": "ok"}""")
##   else:
##     res.setStatus(Http404)
##     res.`end`("Not Found")
##
## server.listen("0.0.0.0", 3000) do(success: bool):
##   if success:
##     echo "Server running at http://localhost:3000"
##   else:
##     echo "Failed to start server"
##
## server.run()
## ```
##
## ## Modules
##
## - `types`: Core type definitions shared across modules
## - `usockets`: Low-level FFI bindings to uSockets C library
## - `http`: High-level HTTP server implementation
## - `websocket`: WebSocket protocol support
##
## ## Building
##
## First, build the uSockets library:
##
## ```nim
## nimble setup  # Clone and build uSockets
## ```
##
## Then compile your application linking against libusockets:
##
## ```nim
## nim c -d:release --passL:"-L./usockets -lusockets" your_app.nim
## ```

# Re-export all public modules
import nim_usockets/types
import nim_usockets/usockets
import nim_usockets/fast_hash
import nim_usockets/http
import nim_usockets/websocket

export types
export usockets
export fast_hash
export http
export websocket
