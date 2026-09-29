import std/unittest
import ../src/nim_usockets/websocket

suite "Standalone WebSocket write policy":
  test "short writes are not treated as successful frames":
    check wsWriteComplete(0, 0)
    check wsWriteComplete(4, 4)
    check not wsWriteComplete(0, 4)
    check not wsWriteComplete(3, 4)

  test "trySend reports failure when connection is unavailable":
    let ws = WebSocketConnection(state: wsOpen)
    check not ws.trySend("hello")

