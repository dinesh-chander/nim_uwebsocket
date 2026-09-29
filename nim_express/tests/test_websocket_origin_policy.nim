import std/unittest

import ../src/nim_express/app

proc wsReq(path, host, origin: string): HttpRequest =
  new(result)
  result.path = path
  result.headers = newFastMap[string]()
  result.headers["host"] = host
  if origin.len > 0:
    result.headers["origin"] = origin

proc installWsValidator(app: ExpressApp) =
  app.ws(proc(ws: WebSocket, message: string, isBinary: bool) =
    discard
  )
  app.setupHandlersForTest()
  check app.server.wsUpgradeValidateHandler != nil

suite "WebSocket origin policy":
  test "default policy allows same-origin and originless clients":
    let webApp = newExpressApp()
    webApp.installWsValidator()

    check webApp.server.wsUpgradeValidateHandler(
      wsReq("/ws", "app.example", "https://app.example")
    )
    check webApp.server.wsUpgradeValidateHandler(
      wsReq("/ws", "app.example:8443", "https://app.example:8443")
    )
    check webApp.server.wsUpgradeValidateHandler(
      wsReq("/ws", "app.example", "")
    )

  test "default policy rejects browser cross-origin websocket upgrades":
    let webApp = newExpressApp()
    webApp.installWsValidator()

    check not webApp.server.wsUpgradeValidateHandler(
      wsReq("/ws", "app.example", "https://evil.example")
    )
    check not webApp.server.wsUpgradeValidateHandler(
      wsReq("/ws", "app.example", "ftp://app.example")
    )
    check not webApp.server.wsUpgradeValidateHandler(
      wsReq("/ws", "app.example", "https://app.example\r\nx: y")
    )

  test "explicit allowlist controls cross-origin websocket upgrades":
    let webApp = newExpressApp()
    webApp.allowWsOrigin("https://trusted.example")
    webApp.installWsValidator()

    check webApp.server.wsUpgradeValidateHandler(
      wsReq("/ws", "app.example", "https://trusted.example")
    )
    check not webApp.server.wsUpgradeValidateHandler(
      wsReq("/ws", "app.example", "https://evil.example")
    )

  test "wildcard allowlist is an explicit open policy":
    let webApp = newExpressApp()
    webApp.allowWsOrigin("*")
    webApp.installWsValidator()

    check webApp.server.wsUpgradeValidateHandler(
      wsReq("/ws", "app.example", "https://evil.example")
    )
