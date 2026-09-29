import std/[options, strutils]
import nim_fasthttpclient/types
import nim_fasthttpclient/ws_client

proc check(cond: bool, msg: string) =
  if not cond:
    quit "FAIL: " & msg

proc bytes(vals: openArray[int]): string =
  result = newStringOfCap(vals.len)
  for v in vals:
    result.add char(v and 0xFF)

proc byteSeq(vals: openArray[int]): seq[byte] =
  result = newSeqOfCap[byte](vals.len)
  for v in vals:
    result.add byte(v and 0xFF)

proc main() =
  var pos = 0
  var read = readWsFrame(bytes([0xC1, 0x00]), pos)
  check(read.status == wfrProtocolError and read.closeCode == 1002'u16, "RSV bits rejected")

  pos = 0
  read = readWsFrame(bytes([0x09, 0x00]), pos)
  check(read.status == wfrProtocolError and read.closeCode == 1002'u16, "fragmented control rejected")

  pos = 0
  read = readWsFrame(bytes([0x89, 0x7E, 0x00, 0x7E]), pos)
  check(read.status == wfrProtocolError and read.closeCode == 1002'u16, "oversized control rejected")

  pos = 0
  read = readWsFrame(bytes([0x81, 0x10]), pos, maxPayloadSize = 4)
  check(read.status == wfrMessageTooLarge and read.closeCode == 1009'u16, "oversized message rejected before payload allocation")

  pos = 0
  read = readWsFrame(bytes([0x81, 0x80, 0x00, 0x00, 0x00, 0x00]), pos, requireUnmasked = true)
  check(read.status == wfrProtocolError and read.closeCode == 1002'u16, "masked server frames rejected")

  pos = 0
  read = readWsFrame(bytes([0x81, 0x7E, 0x00, 0x01, ord('x')]), pos)
  check(read.status == wfrProtocolError and read.closeCode == 1002'u16, "non-canonical 16-bit websocket length rejected")

  pos = 0
  read = readWsFrame(bytes([0x82, 0x7F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]), pos)
  check(read.status == wfrProtocolError and read.closeCode == 1002'u16, "websocket 64-bit length high bit rejected")

  pos = 0
  read = readWsFrame(bytes([0x82, 0x7F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7E]), pos)
  check(read.status == wfrProtocolError and read.closeCode == 1002'u16, "non-canonical 64-bit websocket length rejected")

  pos = 0
  check(decodeWsFrame(byteSeq([0x81, 0x7E, 0x00, 0x01, ord('x')]), pos).isNone, "decoder rejects non-canonical 16-bit websocket length")

  let ws = newWsConnection()
  initWsClientDefaults(ws)
  markWsOpen(ws, 0)
  resetWsUtf8(ws)
  check(feedWsUtf8(ws, "\xE2\x82", final = false), "partial UTF-8 accepted across fragment boundary")
  check(feedWsUtf8(ws, "\xAC", final = true), "completed UTF-8 sequence accepted")

  resetWsUtf8(ws)
  check(feedWsUtf8(ws, "\xC3", final = false), "partial invalid candidate held")
  check(not feedWsUtf8(ws, "\x28", final = true), "bad UTF-8 continuation rejected")

  resetWsUtf8(ws)
  check(not feedWsUtf8(ws, "\xE2\x82", final = true), "truncated UTF-8 rejected at final fragment")

  let keyA = generateWebSocketKey()
  let keyB = generateWebSocketKey()
  check(keyA.len == 24 and keyB.len == 24, "websocket keys are 16 random bytes in base64")
  check(keyA != keyB, "websocket keys should not repeat")

  let frameA = encodeWsFrame(woText, "hello", masked = true)
  let frameB = encodeWsFrame(woText, "hello", masked = true)
  check(frameA != frameB, "masked websocket frames should use fresh masks")

  let longCloseFrame = encodeCloseFrame(1000, repeat("x", 200), masked = true)
  pos = 0
  let decodedClose = decodeWsFrame(cast[seq[byte]](longCloseFrame), pos)
  check(decodedClose.isSome, "long websocket close reason still encodes a parseable close frame")
  check(decodedClose.get.opcode == woClose, "long websocket close reason uses close opcode")
  check(decodedClose.get.payload.len == 125, "websocket close payload is capped to control-frame limit")

  let splitUtf8Reason = repeat("x", 122) & "\xE2\x82\xAC"
  let splitUtf8CloseFrame = encodeCloseFrame(1000, splitUtf8Reason, masked = true)
  pos = 0
  let decodedSplitUtf8Close = decodeWsFrame(cast[seq[byte]](splitUtf8CloseFrame), pos)
  check(decodedSplitUtf8Close.isSome, "split UTF-8 close reason still encodes a parseable close frame")
  check(decodedSplitUtf8Close.get.payload.len == 124, "close reason truncates before partial UTF-8 codepoint")
  check(decodedSplitUtf8Close.get.payload[2..^1] == repeat("x", 122), "close reason preserves only valid UTF-8 prefix")

  echo "test_ws_client_validation: OK"

main()
