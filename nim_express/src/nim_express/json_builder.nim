type
  JsonBuilder* = object
    buf*: string

const DigitPairs = block:
  var s = ""
  for i in 0 ..< 100:
    if i < 10:
      s.add('0')
    s.add($i)
  s

proc appendCopy(buf: var string, src: string, startPos, len: int) {.inline.} =
  if len <= 0:
    return
  let dstPos = buf.len
  buf.setLen(dstPos + len)
  when nimvm:
    for i in 0 ..< len:
      buf[dstPos + i] = src[startPos + i]
  else:
    copyMem(addr buf[dstPos], unsafeAddr src[startPos], len)

## Append the decimal representation of an int to a buffer without allocation.
proc fastIntToStr*(n: int, buf: var string) {.inline.} =
  if n == 0:
    buf.add('0')
    return

  var num = n.int64
  if num < 0:
    if num == low(int64):
      buf.add("-9223372036854775808")
      return
    buf.add('-')
    num = -num

  var digits: array[24, char]
  var p = 0
  while num != 0:
    let idx = int(num mod 100)
    digits[p] = DigitPairs[idx * 2 + 1]
    inc p
    digits[p] = DigitPairs[idx * 2]
    inc p
    num = num div 100

  if digits[p - 1] == '0':
    dec p

  let at = buf.len
  buf.setLen(at + p)
  var dst = at
  var i = p - 1
  while i >= 0:
    buf[dst] = digits[i]
    inc dst
    dec i

## Create a JsonBuilder with a preallocated buffer.
proc initJsonBuilder*(capacity: int = 256): JsonBuilder =
  JsonBuilder(buf: newStringOfCap(capacity))

## Append a raw string to the builder without escaping.
proc add*(b: var JsonBuilder, s: string) {.inline.} =
  b.buf.add(s)

proc addJsonUnicodeEscape(b: var JsonBuilder, ch: char) {.inline.} =
  const HexDigits = "0123456789abcdef"
  let code = ord(ch)
  b.buf.add("\\u00")
  b.buf.add(HexDigits[(code shr 4) and 0x0f])
  b.buf.add(HexDigits[code and 0x0f])

## Append a string as a quoted, JSON-escaped value.
proc addEscaped*(b: var JsonBuilder, s: string) =
  b.buf.add('"')
  var copyStart = 0
  var i = 0

  template flushCopy() =
    if i > copyStart:
      appendCopy(b.buf, s, copyStart, i - copyStart)

  while i < s.len:
    let c = s[i]
    if (cast[uint8](c) and 0b1000_0000'u8) == 0'u8:
      case c
      of '"':
        flushCopy()
        b.buf.add("\\\"")
        inc i
        copyStart = i
      of '\\':
        flushCopy()
        b.buf.add("\\\\")
        inc i
        copyStart = i
      of '\n':
        flushCopy()
        b.buf.add("\\n")
        inc i
        copyStart = i
      of '\r':
        flushCopy()
        b.buf.add("\\r")
        inc i
        copyStart = i
      of '\t':
        flushCopy()
        b.buf.add("\\t")
        inc i
        copyStart = i
      else:
        if ord(c) < 0x20:
          flushCopy()
          b.addJsonUnicodeEscape(c)
          inc i
          copyStart = i
        else:
          inc i
    else:
      inc i

  flushCopy()
  b.buf.add('"')

## Append an int as a JSON number.
proc addInt*(b: var JsonBuilder, v: int) {.inline.} =
  fastIntToStr(v, b.buf)

## Append a bool as a JSON literal.
proc addBool*(b: var JsonBuilder, v: bool) {.inline.} =
  b.buf.add(if v: "true" else: "false")

## Consume the builder and return the completed JSON string.
proc finish*(b: sink JsonBuilder): string {.inline.} =
  move(b.buf)
