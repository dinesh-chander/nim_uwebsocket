import std/unittest

import ../websocketload
import nim_fasthttpclient/types

suite "websocketload stability config":
  test "loopback bind sources are deterministic and bounded":
    check loopbackBindIps(0).len == 0
    check loopbackBindIps(3) == @["127.0.0.2", "127.0.0.3", "127.0.0.4"]
    check loopbackBindIps(300).len == 253

  test "opcode parser accepts text and binary aliases":
    check parseOpcode("text") == woText
    check parseOpcode("txt") == woText
    check parseOpcode("") == woText
    check parseOpcode("binary") == woBinary
    check parseOpcode("bin") == woBinary

  test "worker distribution guard reports hottest thread":
    check worstThread0Load(1000, 8) == 125
    check worstThread0Load(1003, 8) == 128
    check worstThread0Load(1000, 0) == 1000
