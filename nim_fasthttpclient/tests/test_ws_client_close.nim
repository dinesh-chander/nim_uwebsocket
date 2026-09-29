import nim_fasthttpclient/types
import nim_fasthttpclient/ws_client

proc check(cond: bool, msg: string) =
  if not cond:
    quit "FAIL: " & msg

proc closePayload(code: uint16, reason: string = ""): string =
  result = newStringOfCap(2 + reason.len)
  result.add char((code shr 8) and 0xFF)
  result.add char(code and 0xFF)
  result.add reason

proc main() =
  for code in [1000'u16, 1001'u16, 1002'u16, 1003'u16, 1007'u16, 1008'u16, 1009'u16, 1010'u16, 1011'u16, 1012'u16, 1013'u16, 1014'u16, 3000'u16, 4999'u16]:
    check(isValidWsCloseCode(code), "valid close code " & $code)
  for code in [999'u16, 1004'u16, 1005'u16, 1006'u16, 1015'u16, 2999'u16, 5000'u16]:
    check(not isValidWsCloseCode(code), "invalid close code " & $code)
    check(sanitizeOutgoingCloseCode(code) == 1002'u16, "invalid outgoing code sanitized " & $code)

  let clean = parseWsClosePayload(closePayload(1000'u16, "done"))
  check(clean.valid, "clean close payload valid")
  check(clean.code == 1000'u16, "clean close code")
  check(clean.reason == "done", "clean close reason")

  let peerNoStatus = parseWsClosePayload("")
  check(peerNoStatus.valid, "empty peer close payload valid")
  check(peerNoStatus.code == 1005'u16, "empty peer close reports local no-status code")

  let oneByte = parseWsClosePayload("x")
  check(not oneByte.valid and oneByte.closeCode == 1002'u16, "one-byte close payload rejected")

  let forbidden = parseWsClosePayload(closePayload(1006'u16))
  check(not forbidden.valid and forbidden.closeCode == 1002'u16, "forbidden wire close code rejected")

  let badReason = parseWsClosePayload(closePayload(1000'u16, "\xC3\x28"))
  check(not badReason.valid and badReason.closeCode == 1007'u16, "bad UTF-8 close reason rejected")

  let ws = newWsConnection()
  initWsClientDefaults(ws)
  configureReconnect(ws, autoReconnect = true, maxReconnectAttempts = 2)
  check(shouldScheduleWsReconnect(ws, requireLoop = false), "abnormal close can reconnect")
  ws.closeNotified = true
  ws.closeCode = 1006'u16
  check(shouldScheduleWsReconnect(ws, requireLoop = false), "1006 socket loss can reconnect")
  ws.closeCode = 1000'u16
  check(not shouldScheduleWsReconnect(ws, requireLoop = false), "normal peer close suppresses reconnect")
  ws.closeCode = 1002'u16
  check(not shouldScheduleWsReconnect(ws, requireLoop = false), "protocol close suppresses reconnect")
  ws.closeCode = 1012'u16
  check(shouldScheduleWsReconnect(ws, requireLoop = false), "1012 service restart can reconnect")
  ws.closeCode = 1013'u16
  check(shouldScheduleWsReconnect(ws, requireLoop = false), "1013 try again later can reconnect")
  ws.closeCode = 1014'u16
  check(shouldScheduleWsReconnect(ws, requireLoop = false), "1014 bad gateway can reconnect")
  ws.manualClose = true
  ws.closeCode = 1006'u16
  check(not shouldScheduleWsReconnect(ws, requireLoop = false), "manual close suppresses reconnect")

  echo "test_ws_client_close: OK"

main()
