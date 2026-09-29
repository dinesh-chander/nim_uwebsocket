import std/[streams, unittest]

import ../../nim_fastjson

suite "nim_fastjson resource limits":
  test "maxInputBytes rejects oversized string input":
    var opts = defaultFastJsonOptions()
    opts.maxInputBytes = 8
    let fj = initFastJson(opts)

    expect JsonError:
      discard fj.deserialize("[1,2,3,4,5]", seq[int])

  test "maxInputBytes rejects oversized stream input before readAll":
    var opts = defaultFastJsonOptions()
    opts.maxInputBytes = 5
    let fj = initFastJson(opts)
    let stream = newStringStream("[1,2,3]")

    expect JsonError:
      discard fj.deserialize(stream, seq[int])

  test "maxInputBytes makes isValidJson return false for oversized input":
    var opts = defaultFastJsonOptions()
    opts.maxInputBytes = 5
    let fj = initFastJson(opts)

    check not fj.isValidJson("[1,2,3]")
    check not fj.isValidJson(newStringStream("[1,2,3]"))

  test "maxArrayItems rejects oversized arrays":
    var opts = defaultFastJsonOptions()
    opts.maxArrayItems = 3
    let fj = initFastJson(opts)

    expect JsonError:
      discard fj.deserialize("[1,2,3,4]", seq[int])

  test "disabled limits allow larger payloads":
    var opts = defaultFastJsonOptions()
    opts.maxInputBytes = 0
    opts.maxArrayItems = 0
    let fj = initFastJson(opts)

    check fj.deserialize("[1,2,3,4]", seq[int]) == @[1, 2, 3, 4]
