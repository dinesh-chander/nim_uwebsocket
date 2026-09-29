import std/[strutils, unittest]

import ../src/nim_express/paged_buffer

suite "Paged buffer hot TLV elimination":
  test "add and addInt keep output stable across page churn":
    var buf = initPageBuffer(16)
    var expected = newStringOfCap(1024)

    for i in 0..<200:
      buf.add("item:")
      buf.addInt(i)
      buf.add('|')

      expected.add("item:")
      expected.add($i)
      expected.add('|')

    check buf.takeStringAndClear() == expected
    buf.release()

  test "zero-initialized buffer can bind pool lazily":
    var buf: PageBuffer
    buf.pageSize = 32

    for _ in 0..<10:
      buf.add("x")
    buf.addInt(-42)

    let outText = buf.takeStringAndClear()
    check outText == "xxxxxxxxxx-42"
    check outText.endsWith("-42")
    buf.release()

  test "addInt edge case still matches baseline formatting":
    var buf = initPageBuffer(8)
    buf.addInt(low(int))
    check buf.takeStringAndClear() == $low(int)
    buf.release()
