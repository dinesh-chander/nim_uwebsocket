import std/unittest

import ../src/nim_express/paged_buffer

proc asciiView(storage: openArray[char], startPos, viewLen: int): string =
  if viewLen <= 0:
    return ""
  result = newString(viewLen)
  copyMem(addr result[0], unsafeAddr storage[startPos], viewLen)

suite "Paged buffer render primitives":
  test "encodes integers into caller-provided ascii storage":
    var digits: array[24, char]
    let zero = encodeIntAscii(0, digits)
    let zeroText = asciiView(digits, zero.start, zero.len)
    let neg = encodeIntAscii(-12345, digits)
    let negText = asciiView(digits, neg.start, neg.len)
    check zeroText == "0"
    check negText == "-12345"

  test "detects html escapes from pointer-backed payload":
    let plain = "hello world"
    let escaped = "hello<world"
    check not hasHtmlEscapes(unsafeAddr plain[0], plain.len)
    check hasHtmlEscapes(unsafeAddr escaped[0], escaped.len)

  test "appends pointer-backed escaped html into string sink":
    let src = "a&<>'\"z"
    var rendered = ""
    rendered.addHtmlEscaped(unsafeAddr src[0], src.len)
    check rendered == "a&amp;&lt;&gt;&#39;&quot;z"

  test "appends integers into paged buffer using shared encoder":
    var buf = initPageBuffer(16)
    buf.addInt(-90210)
    check buf.takeStringAndClear() == "-90210"
    buf.release()
