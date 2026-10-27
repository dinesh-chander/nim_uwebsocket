import std/[options, parseutils, sets, strutils, tables, unicode]
import std/private/dragonbox
import macrocache
import macros
import ./borrowed

## True when the SSE2 (nimsimd) JSON-safety scan is active for serialization.
## Falls back to the portable SWAR scanner under -d:nimFastjsonPortable or on
## non-x86/unsupported compilers. Workload-dependent win; see docs/design/simd-adoption.md.
const fastjsonScanUseSse2* =
  (hostCPU == "amd64" or hostCPU == "i386") and
  (defined(gcc) or defined(clang)) and
  not defined(js) and not defined(nimFastjsonPortable)

when fastjsonScanUseSse2:
  import nimsimd/sse2

type
  JsonError* = object of ValueError
  JsonSafeString* = distinct string
  JsonAsciiSafeString* = distinct string

## Annotates string fields that never contain characters requiring JSON escaping.
template jsonSafe*() {.pragma.}
  ## Annotate string fields that are known to never contain
  ## characters requiring JSON escaping (", \, control chars).
  ## Skips the SWAR/SIMD safety scan — ~5ns savings per string.

const ObjectFieldPlanCache = CacheTable"nimFastjson.objectFieldPlans"
const DecodeFieldPlanCache = CacheTable"nimFastjson.decodeFieldPlans"
const StaticOverheadCache = CacheTable"nimFastjson.staticOverhead"
const FloatFieldCountCache = CacheTable"nimFastjson.floatFieldCount"
const IntFieldCountCache = CacheTable"nimFastjson.intFieldCount"
const StringFieldCountCache = CacheTable"nimFastjson.stringFieldCount"
const StringOnlyFieldOverheadCache = CacheTable"nimFastjson.stringOnlyFieldOverhead"
const SafeStringOnlyFieldOverheadCache = CacheTable"nimFastjson.safeStringOnlyFieldOverhead"

type
  JsonSerializeFieldKind* = enum
    jsfkGeneric,
    jsfkJsonSafeString,
    jsfkAsciiSafeString

  JsonSerializeRootShape* = enum
    jsrsGeneric,
    jsrsSeqObject,
    jsrsTableObject,
    jsrsNumericTree

  JsonDecodeFieldKind* = enum
    jdfkUnsupported,
    jdfkObject,
    jdfkSeq,
    jdfkArray,
    jdfkOption,
    jdfkRef,
    jdfkString,
    jdfkBool,
    jdfkSignedInt,
    jdfkUnsignedInt,
    jdfkFloat,
    jdfkChar,
    jdfkEnum

  JsonDecodeFieldPlan* = object
    name*: string
    keyLen*: int
    kind*: JsonDecodeFieldKind

  JsonDecodePlan* = object
    fields*: seq[JsonDecodeFieldPlan]

const
  WhiteSpace = {' ', '\n', '\r', '\t'}
  MaxJsonParseDepth = 512

var jsonParseDepth {.threadvar.}: int
# Shared document holder for BorrowedString views created during the current
# deserializeDirect call (avoids one document buffer copy per view).
# Zero means the default `MaxJsonParseDepth` (threadvars cannot be initialized).
var jsonParseDepthLimit {.threadvar.}: int
var jsonMaxArrayItems {.threadvar.}: int

## Sets the per-thread seq parse item limit; a non-positive limit disables it and returns the previous value.
proc setJsonArrayItemLimit*(limit: int): int =
  ## Set the per-thread seq parse item limit. A non-positive limit disables it.
  result = jsonMaxArrayItems
  jsonMaxArrayItems = limit

proc currentJsonArrayItemLimit(): int {.inline.} =
  if jsonMaxArrayItems <= 0: high(int) else: jsonMaxArrayItems

## Sets the per-thread parse depth limit and returns the previous value.
## A non-positive limit falls back to `MaxJsonParseDepth`.
proc setJsonParseDepthLimit*(limit: int): int {.inline.} =
  result = jsonParseDepthLimit
  jsonParseDepthLimit = if limit > 0: limit else: MaxJsonParseDepth

## Conditionally sets the per-thread seq parse item limit when it differs from
## the requested value and reports whether a store happened via `changed`.
## Returns the previous raw value. Avoids redundant threadvar writes when a
## caller repeatedly installs the same limit.
proc setJsonArrayItemLimitIfChanged*(limit: int, changed: var bool): int {.inline.} =
  result = jsonMaxArrayItems
  changed = result != limit
  if changed:
    jsonMaxArrayItems = limit

## Conditionally sets the per-thread parse depth limit when the effective
## value differs from the requested one and reports whether a store happened
## via `changed`. Returns the previous raw value.
proc setJsonParseDepthLimitIfChanged*(limit: int, changed: var bool): int {.inline.} =
  result = jsonParseDepthLimit
  let curEff = if result > 0: result else: MaxJsonParseDepth
  let newEff = if limit > 0: limit else: MaxJsonParseDepth
  changed = curEff != newEff
  if changed:
    jsonParseDepthLimit = newEff

template effectiveParseDepthLimit(): int =
  if jsonParseDepthLimit > 0: jsonParseDepthLimit else: MaxJsonParseDepth

template incJsonDepth() =
  inc jsonParseDepth
  if jsonParseDepth > effectiveParseDepthLimit():
    dec jsonParseDepth
    raise newException(JsonError, "JSON nesting depth exceeds " & $effectiveParseDepthLimit())

template decJsonDepth() =
  dec jsonParseDepth

template rawString(value: JsonSafeString): string =
  cast[string](value)

template rawString(value: JsonAsciiSafeString): string =
  cast[string](value)

template unescapedBodyString(value: string): string =
  value

template unescapedBodyString(value: JsonSafeString): string =
  rawString(value)

template unescapedBodyString(value: JsonAsciiSafeString): string =
  rawString(value)

# SWAR constants — used by scanStringEnd, nextUnsafeJsonByte, etc.
const
  ByteHighBits = 0x8080808080808080'u64
  ByteLowMask = 0x0101010101010101'u64
  ControlFloor = 0x2020202020202020'u64
  QuoteMask = 0x2222222222222222'u64
  SlashMask = 0x5c5c5c5c5c5c5c5c'u64

proc hasZeroByte(word: uint64): bool {.inline.} =
  ((word - ByteLowMask) and (not word) and ByteHighBits) != 0

template escChunkHit(chunk: uint64): bool =
  hasZeroByte(chunk xor QuoteMask) or
  hasZeroByte(chunk xor SlashMask) or
  ((chunk - ControlFloor) and (not chunk) and ByteHighBits) != 0'u64


when defined(release):
  {.push checks: off.}

template jsonError(msg: string, i: int) =
  raise newException(JsonError, msg & " at offset " & $i)

proc checkedJsonAdd(left, right: int; msg = "JSON output too large to serialize"): int {.inline.} =
  if left < 0 or right < 0 or left > high(int) - right:
    raise newException(JsonError, msg)
  left + right

proc checkedJsonMul(left, right: int; msg = "JSON output too large to serialize"): int {.inline.} =
  if left < 0 or right < 0 or (right != 0 and left > high(int) div right):
    raise newException(JsonError, msg)
  left * right

proc checkedJsonInt32(value: int; msg = "JSON string too large to serialize"): int32 {.inline.} =
  if value < 0 or value > int(high(int32)):
    raise newException(JsonError, msg)
  int32(value)

template eatSpace(s: string, i: var int) =
  # Fast bail-out: if first char is not whitespace (common for minified JSON), skip immediately.
  # All JSON whitespace chars are <= 0x20, so a single comparison catches all.
  if i < s.len and s[i] <= ' ':
    while i < s.len and s[i] in WhiteSpace:
      inc i

template expectChar(s: string, i: var int, c: char) =
  eatSpace(s, i)
  if i >= s.len:
    jsonError("expected '" & $c & "' but reached end", i)
  if s[i] != c:
    jsonError("expected '" & $c & "' but got '" & $s[i] & "'", i)
  inc i

proc parseHexInt4(s: string, pos: int): int {.inline.} =
  for ci in pos ..< pos + 4:
    let c = s[ci]
    result = result shl 4
    if c in {'0'..'9'}:
      result = result or (ord(c) - ord('0'))
    elif c in {'a'..'f'}:
      result = result or (ord(c) - ord('a') + 10)
    elif c in {'A'..'F'}:
      result = result or (ord(c) - ord('A') + 10)
    else:
      jsonError("invalid hex digit in \\u escape", ci)

proc parseUnicodeEscape(s: string, i: var int): int =
  inc i
  if i + 4 > s.len:
    jsonError("expected 4 hex digits after \\u", i)
  result = parseHexInt4(s, i)
  i += 3
  if (result and 0xfc00) == 0xdc00:
    jsonError("orphan low surrogate", i)
  if (result and 0xfc00) == 0xd800:
    inc i
    if i >= s.len or s[i] != '\\':
      jsonError("orphan high surrogate", i)
    inc i
    if i >= s.len or s[i] != 'u':
      jsonError("orphan high surrogate", i)
    inc i
    if i + 4 > s.len:
      jsonError("expected 4 hex digits after \\u", i)
    let nextRune = parseHexInt4(s, i)
    i += 3
    if (nextRune and 0xfc00) != 0xdc00:
      jsonError("high surrogate not followed by low surrogate", i)
    result = 0x10000 + (((result - 0xd800) shl 10) or (nextRune - 0xdc00))

proc scanSafeJsonBytes(value: string, start: int): int {.inline.}

## Like `scanSafeJsonBytes`, but also reports via `sawHigh` whether any
## scanned byte is 0x80 or higher. Lets the deserializer skip the separate
## high-byte pass that gates UTF-8 validation: the SIMD/SWAR scan already
## touches every byte, so the non-ASCII test costs one extra compare per
## chunk instead of a whole second scan over the string.
proc scanStringEndWithHigh(value: string, start: int, sawHigh: var bool): int {.inline.} =
  ## Scan for the byte that ends a JSON string, reporting whether the scanned
  ## span contains any non-ASCII byte. Pure-ASCII chunks advance 8 bytes at a
  ## time; the scan drops to byte-exact processing as soon as the region
  ## contains a high byte or a terminator, so `sawHigh` never leaks across
  ## string boundaries.
  let vlen = value.len
  sawHigh = false
  if vlen == 0: return 0
  var idx = start
  while idx + 8 <= vlen:
    var chunk: uint64
    copyMem(addr chunk, unsafeAddr value[idx], 8)
    if (chunk and ByteHighBits) != 0'u64:
      break
    if escChunkHit(chunk):
      break
    idx += 8
  while idx < vlen:
    let c = value[idx]
    if c == '"' or c == '\\' or ord(c) < 0x20:
      return idx
    if ord(c) >= 0x80:
      sawHigh = true
    inc idx
  vlen

proc scanStringEnd(s: string, start: int): int {.inline.} =
  ## Scan for the first byte that ends a JSON string literal: a quote,
  ## a backslash, or a control byte. Delegates to `scanSafeJsonBytes`,
  ## which uses the identical predicate with the SIMD/SWAR scan kernels.
  scanSafeJsonBytes(s, start)

proc ensureValidJsonUtf8(value: string, offset: int) {.inline.} =
  let invalidAt = validateUtf8(value)
  if invalidAt >= 0:
    jsonError("invalid UTF-8 in string", offset + invalidAt)

proc containsHighByte(s: string, start: int = 0, finish: int = -1): bool {.inline.} =
  ## True if any byte in s[start..finish) is 0x80 or higher (non-ASCII).
  ## `finish` defaults to the end of the string. Scans 8 bytes per iteration
  ## with one shift-and-test, so a pure-ASCII span costs roughly one op per
  ## 8 bytes and lets callers skip the full UTF-8 validation pass (ASCII is
  ## valid UTF-8 by definition).
  var i = start
  let n = if finish < 0: s.len else: min(finish, s.len)
  while i + 8 <= n:
    let w = (cast[ptr uint64](unsafeAddr s[i]))[]
    if ((w shr 7) and 0x0101010101010101'u64) != 0:
      return true
    i += 8
  while i < n:
    if ord(s[i]) >= 0x80:
      return true
    i.inc
  false

proc ensureValidJsonUtf8Span(s: string, startIdx, endIdx: int) {.inline.} =
  if endIdx <= startIdx:
    return
  if not containsHighByte(s, startIdx, endIdx):
    return
  let span = s[startIdx ..< endIdx]
  let invalidAt = validateUtf8(span)
  if invalidAt >= 0:
    jsonError("invalid UTF-8 in string", startIdx + invalidAt)

proc appendRuneBytes(dst: var string, outPos: int, r: int): int {.inline.} =
  ## Encodes rune ``r`` as UTF-8 into ``dst`` at ``outPos`` (capacity must
  ## already allow 4 bytes); returns the number of bytes written. Matches the
  ## std/unicode ``add(Rune)`` byte-for-byte, including lone surrogates.
  if r < 0x80:
    dst[outPos] = chr(r)
    1
  elif r < 0x800:
    dst[outPos] = chr(0xC0 or (r shr 6))
    dst[outPos + 1] = chr(0x80 or (r and 0x3F))
    2
  elif r < 0x10000:
    dst[outPos] = chr(0xE0 or (r shr 12))
    dst[outPos + 1] = chr(0x80 or ((r shr 6) and 0x3F))
    dst[outPos + 2] = chr(0x80 or (r and 0x3F))
    3
  else:
    dst[outPos] = chr(0xF0 or (r shr 18))
    dst[outPos + 1] = chr(0x80 or ((r shr 12) and 0x3F))
    dst[outPos + 2] = chr(0x80 or ((r shr 6) and 0x3F))
    dst[outPos + 3] = chr(0x80 or (r and 0x3F))
    4

proc parseJsonStringEscaped(s: string, i: var int, firstHit: int, value: var string) {.inline.} =
  ## Decodes a JSON string body known to contain escapes or control bytes.
  ## The opening quote is already consumed; firstHit is the scan position of
  ## the first escape/control byte. Leaves i past the closing quote.
  ##
  ## GEN-060: the closing quote is located first so the decoded buffer is a
  ## single newStringUninit allocation (raw length is an upper bound — every
  ## escape shrinks); spans and decoded bytes are written straight into it and
  ## it is truncated once at the end, replacing per-span setLen growth and
  ## per-escape add() calls.
  var strEnd = scanStringEnd(s, firstHit)
  while strEnd < s.len and s[strEnd] == '\\':
    # Skip the escaped character and keep locating the closing quote.
    strEnd = scanStringEnd(s, strEnd + 2)
  if strEnd >= s.len:
    jsonError("unterminated string", s.len)
  let rawLen = strEnd - i
  value = newStringUninit(rawLen)
  var outPos = 0
  var copyStart = i

  while true:
    # Resume the SIMD/SWAR scan after every escape so long safe spans between
    # escapes are copied in bulk instead of walked byte by byte.
    let endPos = scanStringEnd(s, copyStart)
    let c = s[endPos]
    if c == '"':
      let spanLen = endPos - copyStart
      if spanLen > 0:
        copyMem(addr value[outPos], unsafeAddr s[copyStart], spanLen)
        outPos += spanLen
      i = endPos + 1
      value.setLen(outPos)
      if containsHighByte(value):
        ensureValidJsonUtf8(value, strEnd - outPos)
      return
    # Span up to the escape/control byte, then decode it.
    let spanLen = endPos - copyStart
    if spanLen > 0:
      copyMem(addr value[outPos], unsafeAddr s[copyStart], spanLen)
      outPos += spanLen
    if c != '\\':
      # The scan predicate guarantees c < ' ' here.
      jsonError("control byte in string", endPos)
    var j = endPos + 1
    if j >= s.len:
      jsonError("expected escaped character", j)
    case s[j]
    of '"', '\\', '/':
      value[outPos] = s[j]
      inc outPos
    of 'b':
      value[outPos] = '\b'
      inc outPos
    of 'f':
      value[outPos] = '\f'
      inc outPos
    of 'n':
      value[outPos] = '\n'
      inc outPos
    of 'r':
      value[outPos] = '\r'
      inc outPos
    of 't':
      value[outPos] = '\t'
      inc outPos
    of 'u':
      let r = parseUnicodeEscape(s, j)
      outPos += appendRuneBytes(value, outPos, r)
    else:
      jsonError("invalid escape character", j)
    copyStart = j + 1

proc parseJsonString(s: string, i: var int, value: var string) =
  eatSpace(s, i)
  if i + 3 < s.len and s[i] == 'n' and s[i + 1] == 'u' and s[i + 2] == 'l' and s[i + 3] == 'l':
    jsonError("string expected", i)

  expectChar(s, i, '"')

  # Fast path: SIMD/SWAR-scan for end of string or first escape, tracking
  # non-ASCII bytes in the same pass so no second scan is needed.
  var sawHigh = false
  let endPos = scanStringEndWithHigh(s, i, sawHigh)
  if endPos < s.len and s[endPos] == '"':
    # No escapes — single allocation + copyMem
    let slen = endPos - i
    if slen <= 0:
      value.setLen(0)
    else:
      value = newStringUninit(slen)
      copyMem(addr value[0], unsafeAddr s[i], slen)
      # ASCII strings are valid UTF-8 by definition — only pay for the full
      # validation pass when the string actually contains high bytes.
      if sawHigh:
        ensureValidJsonUtf8(value, i)
    i = endPos + 1
    return

  # Slow path: string has escapes or control chars
  parseJsonStringEscaped(s, i, endPos, value)

proc parseObjectKeySpan(s: string, i: var int, keyStart, keyLen: var int): bool =
  eatSpace(s, i)
  if i >= s.len:
    jsonError("expected object key", i)
  if s[i] != '"':
    jsonError("expected '\"' but got '" & $s[i] & "'", i)

  keyStart = i + 1
  let endPos = scanStringEnd(s, keyStart)
  if endPos < s.len and s[endPos] == '"':
    # UTF-8 validation is deferred to the unknown-key branch: a span that
    # equals a known ASCII field literal is valid UTF-8 by construction, so
    # known fields skip the high-byte scan entirely.
    keyLen = endPos - keyStart
    i = endPos + 1
    return true
  return false  # has escape or control char — fall back to slow path

proc skipJsonValue*(s: string, i: var int)

proc skipUnknownJsonKey(s: string, keyStart, keyLen: int, i: var int) {.inline.} =
  ## Validates the (unmatched) object key span as UTF-8, then skips its value.
  ## Known-field spans never reach here: matching an ASCII literal already
  ## proves the span is valid UTF-8.
  ensureValidJsonUtf8Span(s, keyStart, keyStart + keyLen)
  skipJsonValue(s, i)

func loadU32(s: static string, off: static int): uint32 =
  ## Load up to 4 bytes from a static string into a uint32 at compile time.
  var r: uint32 = 0
  for i in 0 ..< min(4, s.len - off):
    r = r or (uint32(ord(s[off + i])) shl (i * 8))
  r

func loadU64(s: static string, off: static int): uint64 =
  ## Load up to 8 bytes from a static string into a uint64 at compile time.
  var r: uint64 = 0
  for i in 0 ..< min(8, s.len - off):
    r = r or (uint64(ord(s[off + i])) shl (i * 8))
  r

proc spanEquals(s: string, startIdx, spanLen: int, literal: static string): bool {.inline.} =
  ## Word-at-a-time field name comparison with compile-time dispatch.
  ## `literal` is static, so the compiler knows its length at compile time and
  ## dead-code-eliminates all non-matching `when` branches.  The reference
  ## side is pre-computed as a compile-time uint32/uint64 constant — only
  ## the input side needs a runtime load.
  if spanLen != literal.len:
    return false
  when literal.len == 0:
    true
  elif literal.len == 1:
    s[startIdx] == literal[0]
  elif literal.len <= 3:
    const expected = loadU32(literal, 0)
    var a: uint32
    copyMem(addr a, unsafeAddr s[startIdx], literal.len)
    a == expected
  elif literal.len == 4:
    const expected = loadU32(literal, 0)
    var a: uint32
    copyMem(addr a, unsafeAddr s[startIdx], 4)
    a == expected
  elif literal.len <= 7:
    # Overlap trick: compare first 4 + last 4 bytes
    const exp1 = loadU32(literal, 0)
    const exp2 = loadU32(literal, literal.len - 4)
    var a1, a2: uint32
    copyMem(addr a1, unsafeAddr s[startIdx], 4)
    copyMem(addr a2, unsafeAddr s[startIdx + literal.len - 4], 4)
    (a1 == exp1) and (a2 == exp2)
  elif literal.len == 8:
    const expected = loadU64(literal, 0)
    var a: uint64
    copyMem(addr a, unsafeAddr s[startIdx], 8)
    a == expected
  elif literal.len <= 15:
    # Overlap trick with uint64: first 8 + last 8
    const exp1 = loadU64(literal, 0)
    const exp2 = loadU64(literal, literal.len - 8)
    var a1, a2: uint64
    copyMem(addr a1, unsafeAddr s[startIdx], 8)
    copyMem(addr a2, unsafeAddr s[startIdx + literal.len - 8], 8)
    (a1 == exp1) and (a2 == exp2)
  elif literal.len == 16:
    const exp1 = loadU64(literal, 0)
    const exp2 = loadU64(literal, 8)
    var a1, a2: uint64
    copyMem(addr a1, unsafeAddr s[startIdx], 8)
    copyMem(addr a2, unsafeAddr s[startIdx + 8], 8)
    (a1 == exp1) and (a2 == exp2)
  else:
    # 17+ byte field names: fall back to equalMem
    var lit = literal  # materialize static string for addressability
    equalMem(unsafeAddr s[startIdx], unsafeAddr lit[0], spanLen)

proc skipUnicodeEscape(s: string, i: var int) =
  if i + 4 > s.len:
    jsonError("expected 4 hex digits after \\u", i)
  for ci in i ..< i + 4:
    if s[ci] notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      jsonError("invalid hex digit in \\u escape", ci)
  let cp = parseHexInt4(s, i)
  i += 4
  if (cp and 0xfc00) == 0xdc00:
    jsonError("orphan low surrogate", i - 1)
  if (cp and 0xfc00) == 0xd800:
    if i + 1 >= s.len or s[i] != '\\' or s[i + 1] != 'u':
      jsonError("orphan high surrogate", i - 1)
    i += 2
    if i + 4 > s.len:
      jsonError("expected 4 hex digits after \\u", i)
    for ci in i ..< i + 4:
      if s[ci] notin {'0'..'9', 'a'..'f', 'A'..'F'}:
        jsonError("invalid hex digit in \\u escape", ci)
    let low = parseHexInt4(s, i)
    i += 4
    if (low and 0xfc00) != 0xdc00:
      jsonError("high surrogate not followed by low surrogate", i - 1)

proc skipJsonString(s: string, i: var int) =
  eatSpace(s, i)
  if i + 3 < s.len and s[i] == 'n' and s[i + 1] == 'u' and s[i + 2] == 'l' and s[i + 3] == 'l':
    i += 4
    return
  expectChar(s, i, '"')
  while true:
    var sawHigh = false
    let endPos = scanStringEndWithHigh(s, i, sawHigh)
    if sawHigh:
      ensureValidJsonUtf8Span(s, i, endPos)
    i = endPos
    if i >= s.len:
      jsonError("unterminated string", i)
    if s[i] == '"':
      inc i
      return
    if s[i] == '\\':
      inc i
      if i >= s.len:
        jsonError("expected escaped character", i)
      case s[i]
      of '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
        inc i
      of 'u':
        inc i
        skipUnicodeEscape(s, i)
      else:
        jsonError("invalid escape character", i)
      continue
    if ord(s[i]) < 0x20:
      jsonError("unescaped control character in string", i)
    inc i

proc skipJsonArray(s: string, i: var int) =
  expectChar(s, i, '[')
  incJsonDepth()
  defer: decJsonDepth()
  eatSpace(s, i)
  if i < s.len and s[i] == ']':
    inc i
    return
  while true:
    skipJsonValue(s, i)
    eatSpace(s, i)
    if i >= s.len:
      jsonError("unterminated array", i)
    if s[i] == ']':
      inc i
      return
    expectChar(s, i, ',')

proc skipJsonObjectKey(s: string, i: var int) =
  eatSpace(s, i)
  if i >= s.len:
    jsonError("expected object key", i)
  if s[i] != '"':
    jsonError("object key must be a string", i)
  inc i
  while true:
    var sawHigh = false
    let endPos = scanStringEndWithHigh(s, i, sawHigh)
    if sawHigh:
      ensureValidJsonUtf8Span(s, i, endPos)
    i = endPos
    if i >= s.len:
      jsonError("unterminated string", i)
    if s[i] == '"':
      inc i
      return
    if s[i] == '\\':
      inc i
      if i >= s.len:
        jsonError("expected escaped character", i)
      case s[i]
      of '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
        inc i
      of 'u':
        inc i
        skipUnicodeEscape(s, i)
      else:
        jsonError("invalid escape character", i)
      continue
    if ord(s[i]) < 0x20:
      jsonError("unescaped control character in string", i)
    inc i

proc skipJsonObject(s: string, i: var int) =
  expectChar(s, i, '{')
  incJsonDepth()
  defer: decJsonDepth()
  eatSpace(s, i)
  if i < s.len and s[i] == '}':
    inc i
    return
  while true:
    skipJsonObjectKey(s, i)
    expectChar(s, i, ':')
    skipJsonValue(s, i)
    eatSpace(s, i)
    if i >= s.len:
      jsonError("unterminated object", i)
    if s[i] == '}':
      inc i
      return
    expectChar(s, i, ',')

proc skipJsonNumber(s: string, i: var int) =
  eatSpace(s, i)
  let start = i
  if i < s.len and s[i] == '-':
    inc i
  if i >= s.len or s[i] notin {'0'..'9'}:
    jsonError("number expected", i)
  if s[i] == '0':
    inc i
    if i < s.len and s[i] in {'0'..'9'}:
      jsonError("leading zeros not allowed in JSON numbers", i)
  else:
    while i < s.len and s[i] in {'0'..'9'}:
      inc i
  if i < s.len and s[i] == '.':
    inc i
    let fracStart = i
    while i < s.len and s[i] in {'0'..'9'}:
      inc i
    if i == fracStart:
      jsonError("fraction part must have at least one digit", i)
  if i < s.len and (s[i] == 'e' or s[i] == 'E'):
    inc i
    if i < s.len and (s[i] == '+' or s[i] == '-'):
      inc i
    let expStart = i
    while i < s.len and s[i] in {'0'..'9'}:
      inc i
    if i == expStart:
      jsonError("exponent part must have at least one digit", i)
    if i - expStart > 10:
      jsonError("exponent too large", expStart)
  if i == start:
    jsonError("number expected", i)

proc skipJsonKeyword(s: string, i: var int, keyword: string) =
  for ch in keyword:
    if i >= s.len or s[i] != ch:
      jsonError("expected keyword " & keyword, i)
    inc i

## Advances the parse index past one JSON value of any kind, validating its structure.
proc skipJsonValue*(s: string, i: var int) =
  eatSpace(s, i)
  if i >= s.len:
    jsonError("expected json value", i)
  case s[i]
  of '"':
    skipJsonString(s, i)
  of '{':
    skipJsonObject(s, i)
  of '[':
    skipJsonArray(s, i)
  of 't':
    skipJsonKeyword(s, i, "true")
  of 'f':
    skipJsonKeyword(s, i, "false")
  of 'n':
    skipJsonKeyword(s, i, "null")
  else:
    skipJsonNumber(s, i)

## Parses a JSON array into a seq of T.
proc parseValue*[T](s: string, i: var int, value: var seq[T])
## Parses a JSON object into a ref object T, creating it when non-null.
proc parseValue*[T: ref object](s: string, i: var int, value: var T)
## Parses a JSON object into a value object T.
proc parseValue*[T: object](s: string, i: var int, value: var T)
## Parses a JSON value into an Option of T, mapping null to none.
proc parseValue*[T](s: string, i: var int, value: var Option[T])
## Parses a JSON object into a Table of A to B.
proc parseValue*[A, B](s: string, i: var int, value: var Table[A, B])
## Parses a JSON object into an OrderedTable of A to B.
proc parseValue*[A, B](s: string, i: var int, value: var OrderedTable[A, B])

## Parses a JSON true or false literal into value.
proc parseValue*(s: string, i: var int, value: var bool) =
  eatSpace(s, i)
  if i + 3 < s.len and s[i] == 't' and s[i + 1] == 'r' and s[i + 2] == 'u' and s[i + 3] == 'e':
    i += 4
    value = true
  elif i + 4 < s.len and s[i] == 'f' and s[i + 1] == 'a' and s[i + 2] == 'l' and s[i + 3] == 's' and s[i + 4] == 'e':
    i += 5
    value = false
  else:
    jsonError("boolean expected", i)

## Parses a JSON unsigned integer into value.
proc parseValue*(s: string, i: var int, value: var SomeUnsignedInt) =
  eatSpace(s, i)
  var raw: uint64 = 0
  let start = i
  if i >= s.len or s[i] notin {'0'..'9'}:
    jsonError("unsigned integer expected", i)
  if s[i] == '0':
    inc i
    if i < s.len and s[i] in {'0'..'9'}:
      jsonError("leading zeros not allowed in JSON numbers", i)
    value = type(value)(0)
    return
  # Two digits per iteration halves the loop work for multi-digit numbers.
  while i + 1 < s.len and s[i] in {'0'..'9'} and s[i + 1] in {'0'..'9'}:
    let pair = uint64((ord(s[i]) - ord('0')) * 10 + (ord(s[i + 1]) - ord('0')))
    if raw > (high(uint64) - pair) div 100:
      jsonError("unsigned integer overflow", i)
    raw = raw * 100'u64 + pair
    i += 2
  if i < s.len and s[i] in {'0'..'9'}:
    let digit = uint64(ord(s[i]) - ord('0'))
    if raw > (high(uint64) - digit) div 10:
      jsonError("unsigned integer overflow", i)
    raw = raw * 10'u64 + digit
    inc i
  if start == i:
    jsonError("unsigned integer expected", i)
  when type(value) isnot uint64:
    if raw > uint64(high(type(value))):
      jsonError("unsigned integer out of range", i)
  value = type(value)(raw)

## Parses a JSON signed integer into value.
proc parseValue*(s: string, i: var int, value: var SomeSignedInt) =
  eatSpace(s, i)
  var negative = false
  if i < s.len and s[i] == '-':
    negative = true
    inc i
  var raw: uint64
  parseValue(s, i, raw)
  if negative:
    const MinInt64Magnitude = uint64(high(int64)) + 1'u64
    if raw > MinInt64Magnitude:
      jsonError("signed integer overflow", i)
    let signed =
      if raw == MinInt64Magnitude:
        low(int64)
      else:
        -int64(raw)
    when type(value) isnot int64:
      if signed < int64(low(type(value))) or signed > int64(high(type(value))):
        jsonError("signed integer out of range", i)
    value = type(value)(signed)
  else:
    if raw > uint64(high(type(value))):
      jsonError("signed integer out of range", i)
    value = type(value)(raw)

const U64Pow10Table = [1'u64, 10'u64, 100'u64, 1000'u64, 10000'u64, 100000'u64, 1000000'u64, 10000000'u64, 100000000'u64, 1000000000'u64, 10000000000'u64, 100000000000'u64, 1000000000000'u64, 10000000000000'u64, 100000000000000'u64, 1000000000000000'u64, 10000000000000000'u64, 100000000000000000'u64, 1000000000000000000'u64, 10000000000000000000'u64]
const U64Pow10Limit = [18446744073709551615u64, 1844674407370955161u64, 184467440737095516u64, 18446744073709551u64, 1844674407370955u64, 184467440737095u64, 18446744073709u64, 1844674407370u64, 184467440737u64, 18446744073u64, 1844674407u64, 184467440u64, 18446744u64, 1844674u64, 184467u64, 18446u64, 1844u64, 184u64, 18u64, 1u64]

const Pow10Table = [1e-22, 1e-21, 1e-20, 1e-19, 1e-18, 1e-17, 1e-16, 1e-15, 1e-14, 1e-13, 1e-12, 1e-11, 1e-10, 1e-9, 1e-8, 1e-7, 1e-6, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1, 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22]

## Parses a JSON number into a float value.
proc parseValue*(s: string, i: var int, value: var SomeFloat) =
  eatSpace(s, i)
  if i < s.len and s[i] == '+':
    jsonError("leading '+' not allowed in JSON numbers", i)
  let start = i
  var j = i
  var negative = false
  if j < s.len and s[j] == '-':
    negative = true
    inc j

  if j >= s.len or s[j] notin {'0'..'9'}:
    jsonError("float expected", i)

  var intPart: uint64 = 0
  var intDigits = 0
  var fallbackToParseFloat = false
  if s[j] == '0':
    inc j
    inc intDigits
    if j < s.len and s[j] in {'0'..'9'}:
      jsonError("leading zeros not allowed in JSON numbers", j)
  else:
    while j + 1 < s.len and s[j] in {'0'..'9'} and s[j + 1] in {'0'..'9'}:
      let pair = uint64((ord(s[j]) - ord('0')) * 10 + (ord(s[j + 1]) - ord('0')))
      if intPart > (high(uint64) - pair) div 100'u64:
        fallbackToParseFloat = true
      elif not fallbackToParseFloat:
        intPart = intPart * 100'u64 + pair
      j += 2
      intDigits += 2
    if j < s.len and s[j] in {'0'..'9'}:
      let digit = uint64(ord(s[j]) - ord('0'))
      if intPart > (high(uint64) - digit) div 10'u64:
        fallbackToParseFloat = true
      elif not fallbackToParseFloat:
        intPart = intPart * 10'u64 + digit
      inc j
      inc intDigits

  var fracPart: uint64 = 0
  var fracScale = 1.0
  var fracDigits = 0
  if j < s.len and s[j] == '.':
    inc j
    if j >= s.len or s[j] notin {'0'..'9'}:
      jsonError("fraction part must have at least one digit", j)
    while j + 1 < s.len and s[j] in {'0'..'9'} and s[j + 1] in {'0'..'9'}:
      let pair = uint64((ord(s[j]) - ord('0')) * 10 + (ord(s[j + 1]) - ord('0')))
      if fracDigits + 2 > 15 or fracPart > (high(uint64) - pair) div 100'u64:
        fallbackToParseFloat = true
      elif not fallbackToParseFloat:
        fracPart = fracPart * 100'u64 + pair
        fracScale *= 100.0
      j += 2
      fracDigits += 2
    if j < s.len and s[j] in {'0'..'9'}:
      let digit = uint64(ord(s[j]) - ord('0'))
      if fracDigits >= 15 or fracPart > (high(uint64) - digit) div 10'u64:
        fallbackToParseFloat = true
      elif not fallbackToParseFloat:
        fracPart = fracPart * 10'u64 + digit
        fracScale *= 10.0
      inc j
      inc fracDigits

  if j < s.len and (s[j] == 'e' or s[j] == 'E'):
    inc j
    let expIsNeg = j < s.len and s[j] == '-'
    if j < s.len and (s[j] == '+' or s[j] == '-'):
      inc j
    let expStart = j
    if j >= s.len or s[j] notin {'0'..'9'}:
      jsonError("exponent part must have at least one digit", j)
    var expNeg = false
    var expVal = 0
    while j < s.len and s[j] in {'0'..'9'}:
      expVal = expVal * 10 + (ord(s[j]) - ord('0'))
      if expVal > 100000:
        expVal = 100000
      inc j
    if j - expStart > 10:
      jsonError("exponent too large", expStart)
    var parsed: float
    var done = false
    if not fallbackToParseFloat and intDigits + fracDigits <= 15:
      # Exact path: fold the decimal point into an integer mantissa M
      # (M <= 10^15 - 1), then either scale M by 10^e as an exact uint64
      # (positive exponents) or divide two exactly representable doubles
      # (|e| <= 15 keeps 10^e below 2^53). Both round exactly once, matching
      # a correctly rounded strtod, so no ULP drift is possible.
      var m = intPart
      for _ in 0 ..< fracDigits:
        m *= 10'u64
      m += fracPart
      let eNet = (if expIsNeg: -expVal else: expVal) - fracDigits
      if eNet == 0:
        parsed = float64(m)
        done = true
      elif eNet < 0:
        let shift = -eNet
        if shift <= 15:
          parsed = float64(m) / Pow10Table[shift + 22]
          done = true
      elif eNet <= 19 and m <= U64Pow10Limit[eNet]:
        parsed = float64(m * U64Pow10Table[eNet])
        done = true
      if done:
        if negative:
          parsed = -parsed
        i = j
    if not done:
      let consumed = parseFloat(s, parsed, start)
      if consumed == 0:
        jsonError("float expected", i)
      i = start + consumed
    if parsed != parsed or parsed == Inf or parsed == NegInf:
      jsonError("NaN/Infinity not allowed in JSON", i)
    value = type(value)(parsed)
    return

  if fallbackToParseFloat or intDigits > 15 or fracDigits > 15:
    var parsed: float
    let consumed = parseFloat(s, parsed, start)
    if consumed == 0 or start + consumed != j:
      jsonError("float expected", i)
    if parsed != parsed or parsed == Inf or parsed == NegInf:
      jsonError("NaN/Infinity not allowed in JSON", i)
    i = j
    value = type(value)(parsed)
    return

  var parsed = float64(intPart)
  if fracDigits > 0:
    parsed += float64(fracPart) / fracScale
  if negative:
    parsed = -parsed
  i = j
  value = type(value)(parsed)

## Parses a JSON string literal into value.
proc parseValue*(s: string, i: var int, value: var string) =
  parseJsonString(s, i, value)

# One shared document owner per thread. Every escape-free view of the most
# recently parsed document shares this single reference; the identity check
# creates a new owner only when a different buffer comes in. The template
# form keeps the (rare) creation code out of the hot path's register plan.
var tjBorrowDoc {.threadvar.}: BorrowedDocRef
var tjBorrowDocSrc {.threadvar.}: pointer

template borrowedDocHolderFor(s: string): BorrowedDocRef =
  var holder = tjBorrowDoc
  # Identity by the SOURCE buffer pointer (O(1)). The previous check compared
  # `s.cstring != holder.doc.cstring`, which materialized/strcmp-ed the WHOLE
  # document on every borrowed field -> O(n^2) decode (measured ~39x slower
  # than owned-string decode on a seq of 1000 strings). We remember the source
  # pointer that created the current holder so a document reused across its
  # fields allocates exactly one owner.
  let p = if s.len > 0: cast[pointer](unsafeAddr s[0]) else: nil
  if holder.isNil or p != tjBorrowDocSrc:
    holder = newBorrowedDocRef(s)
    tjBorrowDoc = holder
    tjBorrowDocSrc = p
    tjBorrowDoc = holder
  holder

proc parseValue*(s: string, i: var int, value: var BorrowedString) {.inline.} =
  eatSpace(s, i)
  if i + 3 < s.len and s[i] == 'n' and s[i + 1] == 'u' and s[i + 2] == 'l' and s[i + 3] == 'l':
    # JSON null decodes to a nil view.
    value = BorrowedString()
    i += 4
    return

  expectChar(s, i, '"')

  # Fast path: no escapes — the view points straight into the document.
  var sawHigh = false
  let endPos = scanStringEndWithHigh(s, i, sawHigh)
  if endPos < s.len and s[endPos] == '"':
    if sawHigh:
      ensureValidJsonUtf8Span(s, i, endPos)
    setBorrowedDocView(value, borrowedDocHolderFor(s),
                       cast[cstring](unsafeAddr s[i]), endPos - i)
    i = endPos + 1
    return

  # Slow path: escapes present — decode into a fresh buffer that the view
  # owns outright.
  var decoded = ""
  parseJsonStringEscaped(s, i, endPos, decoded)
  # The view owns its decoded buffer outright.
  value = borrowOwned(decoded)

proc parseEnumJsonString[T: enum](s: string, i: var int, value: var T) {.inline.} =
  let start = i
  var raw = ""
  parseJsonString(s, i, raw)
  try:
    value = parseEnum[T](raw)
  except ValueError:
    jsonError("invalid enum value " & raw, start)

## Parses a JSON string into an enum value by name.
proc parseValue*[T: enum](s: string, i: var int, value: var T) =
  parseEnumJsonString(s, i, value)

## Parses a JSON array into a seq of T.
proc parseValue*[T](s: string, i: var int, value: var seq[T]) =
  eatSpace(s, i)
  if i + 3 < s.len and s[i] == 'n' and s[i + 1] == 'u' and s[i + 2] == 'l' and s[i + 3] == 'l':
    jsonError("array expected", i)
  expectChar(s, i, '[')
  incJsonDepth()
  defer: decJsonDepth()
  value.setLen(0)
  eatSpace(s, i)
  if i < s.len and s[i] == ']':
    inc i
    return
  value = newSeqOfCap[T](16)
  let maxItems = currentJsonArrayItemLimit()
  while true:
    if value.len >= maxItems:
      jsonError("JSON array item limit exceeds " & $maxItems, i)
    var item: T
    parseValue(s, i, item)
    value.add(item)
    if i < s.len:
      if s[i] == ',':
        inc i
        continue
      if s[i] == ']':
        inc i
        return
    eatSpace(s, i)
    if i >= s.len:
      jsonError("unterminated array", i)
    if s[i] == ']':
      inc i
      return
    expectChar(s, i, ',')

## Parses a JSON object into a ref object T, creating it when non-null.
proc parseValue*[T: ref object](s: string, i: var int, value: var T) =
  eatSpace(s, i)
  if i + 3 < s.len and s[i] == 'n' and s[i + 1] == 'u' and s[i + 2] == 'l' and s[i + 3] == 'l':
    i += 4
    value = nil
    return
  new(value)
  parseValue(s, i, value[])

## Parses a JSON value into an Option of T, mapping null to none.
proc parseValue*[T](s: string, i: var int, value: var Option[T]) =
  eatSpace(s, i)
  if i + 3 < s.len and s[i] == 'n' and s[i + 1] == 'u' and s[i + 2] == 'l' and s[i + 3] == 'l':
    i += 4
    value = none(T)
    return
  var inner: T
  parseValue(s, i, inner)
  value = some(inner)

## Parses a JSON object into a Table of A to B.
proc parseValue*[A, B](s: string, i: var int, value: var Table[A, B]) =
  eatSpace(s, i)
  expectChar(s, i, '{')
  incJsonDepth()
  defer: decJsonDepth()
  value = initTable[A, B]()
  eatSpace(s, i)
  if i < s.len and s[i] == '}':
    inc i
    return
  while true:
    eatSpace(s, i)
    if i >= s.len or s[i] != '"':
      jsonError("object key must be a string", i)
    var key: A
    when A is string:
      parseValue(s, i, key)
    elif A is enum:
      parseEnumJsonString(s, i, key)
    else:
      {.error: "Table key must be string or enum".}
    eatSpace(s, i)
    expectChar(s, i, ':')
    var val: B
    parseValue(s, i, val)
    value[key] = val
    eatSpace(s, i)
    if i >= s.len:
      jsonError("unterminated object", i)
    if s[i] == '}':
      inc i
      return
    expectChar(s, i, ',')

## Parses a JSON object into an OrderedTable of A to B.
proc parseValue*[A, B](s: string, i: var int, value: var OrderedTable[A, B]) =
  eatSpace(s, i)
  expectChar(s, i, '{')
  incJsonDepth()
  defer: decJsonDepth()
  value = initOrderedTable[A, B]()
  eatSpace(s, i)
  if i < s.len and s[i] == '}':
    inc i
    return
  while true:
    eatSpace(s, i)
    if i >= s.len or s[i] != '"':
      jsonError("object key must be a string", i)
    var key: A
    when A is string:
      parseValue(s, i, key)
    elif A is enum:
      parseEnumJsonString(s, i, key)
    else:
      {.error: "OrderedTable key must be string or enum".}
    eatSpace(s, i)
    expectChar(s, i, ':')
    var val: B
    parseValue(s, i, val)
    value[key] = val
    eatSpace(s, i)
    if i >= s.len:
      jsonError("unterminated object", i)
    if s[i] == '}':
      inc i
      return
    expectChar(s, i, ',')

proc extractFieldName(node: NimNode): string =
  case node.kind
  of nnkPostfix:
    $node[1]
  of nnkPragmaExpr:
    extractFieldName(node[0])
  of nnkIdent, nnkSym:
    $node
  else:
    node.repr

proc fieldNodeHasPragma(node: NimNode, pragmaName: string): bool =
  ## Check if a field IdentDefs entry has a specific pragma.
  ## Field AST: nnkIdentDefs(nnkPragmaExpr(name, nnkPragma(...)), type, default)
  if node.kind == nnkPragmaExpr and node.len >= 2:
    let pragmaList = node[1]
    if pragmaList.kind == nnkPragma:
      for p in pragmaList:
        if p.kind in {nnkIdent, nnkSym} and eqIdent(p, pragmaName):
          return true
  false

proc objectTypeInfo(value: NimNode): tuple[key: string, impl: NimNode] =
  var valueType = value.getTypeInst
  if valueType.kind == nnkRefTy:
    valueType = valueType[0]
  var impl = getTypeImpl(valueType)
  if impl.kind == nnkSym:
    impl = getTypeImpl(impl)
  if impl.kind == nnkRefTy:
    impl = getTypeImpl(impl[0])
  if impl.kind != nnkObjectTy:
    error("object operation expects an object type", value)
  result = (impl.repr, impl)

proc objectFieldPlanNode(value: NimNode): NimNode =
  let info = objectTypeInfo(value)
  if ObjectFieldPlanCache.hasKey(info.key):
    return ObjectFieldPlanCache[info.key]

  result = nnkBracket.newTree()
  for field in info.impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    for idx in 0 ..< field.len - 2:
      let fieldName = extractFieldName(field[idx])
      result.add(nnkTupleConstr.newTree(
        newLit(fieldName),
        newLit("\"" & fieldName & "\":")
      ))
  ObjectFieldPlanCache[info.key] = result

proc objectFieldEntries(value: NimNode): seq[(string, NimNode)] =
  let plan = objectFieldPlanNode(value)
  for entry in plan:
    let fieldName = entry[0].strVal
    result.add((fieldName, nnkDotExpr.newTree(value, ident(fieldName))))

proc unwrapTypedescNodeLocal(typeNode: NimNode): NimNode =
  let typeInst = typeNode.getTypeInst
  if typeInst.kind == nnkBracketExpr and typeInst.len == 2 and eqIdent(typeInst[0], "typedesc"):
    typeInst[1]
  else:
    typeNode

proc supportedObjectRecListLocal(typeNode: NimNode): NimNode =
  let concrete = unwrapTypedescNodeLocal(typeNode)
  if concrete.kind != nnkSym:
    return newEmptyNode()
  let impl = concrete.getImpl
  if impl.kind == nnkTypeDef and impl.len >= 3:
    let objectTy = impl[2]
    if objectTy.kind == nnkObjectTy and objectTy.len >= 3 and objectTy[2].kind == nnkRecList:
      return objectTy[2]
  newEmptyNode()

proc objectTypeInfoFromTypeNode(typeNode: NimNode): tuple[key: string, impl: NimNode] =
  let concrete = unwrapTypedescNodeLocal(typeNode)
  if concrete.kind != nnkSym:
    error("decode plan expects a concrete object type", typeNode)
  var impl = concrete.getImpl
  if impl.kind == nnkTypeDef and impl.len >= 3:
    impl = impl[2]
  if impl.kind == nnkRefTy:
    impl = getTypeImpl(impl[0])
  if impl.kind != nnkObjectTy:
    error("decode plan expects an object type", typeNode)
  result = (impl.repr, impl)

proc decodeFieldKindNode(typeNode: NimNode): NimNode =
  let typeInst = typeNode.getTypeInst
  if typeInst.kind == nnkBracketExpr:
    if typeInst.len == 2 and eqIdent(typeInst[0], "Option"):
      return bindSym"jdfkOption"
    if typeInst.len == 2 and eqIdent(typeInst[0], "seq"):
      return bindSym"jdfkSeq"
    if typeInst.len == 3 and eqIdent(typeInst[0], "array"):
      return bindSym"jdfkArray"
  if typeNode.kind == nnkRefTy or (typeInst.kind == nnkRefTy):
    return bindSym"jdfkRef"
  let recList = supportedObjectRecListLocal(typeNode)
  if recList.kind == nnkRecList:
    return bindSym"jdfkObject"
  case typeNode.typeKind
  of ntyString:
    bindSym"jdfkString"
  of ntyBool:
    bindSym"jdfkBool"
  of ntyInt, ntyInt8, ntyInt16, ntyInt32, ntyInt64:
    bindSym"jdfkSignedInt"
  of ntyUInt, ntyUInt8, ntyUInt16, ntyUInt32, ntyUInt64:
    bindSym"jdfkUnsignedInt"
  of ntyFloat, ntyFloat32, ntyFloat64:
    bindSym"jdfkFloat"
  of ntyChar:
    bindSym"jdfkChar"
  of ntyEnum:
    bindSym"jdfkEnum"
  else:
    bindSym"jdfkUnsupported"

proc objectDecodePlanNode(typeNode: NimNode): NimNode =
  let info = objectTypeInfoFromTypeNode(typeNode)
  if DecodeFieldPlanCache.hasKey(info.key):
    return DecodeFieldPlanCache[info.key]

  result = nnkBracket.newTree()
  for field in info.impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[^2]
    let kindNode = decodeFieldKindNode(fieldType)
    for idx in 0 ..< field.len - 2:
      let fieldName = extractFieldName(field[idx])
      result.add(nnkObjConstr.newTree(
        bindSym"JsonDecodeFieldPlan",
        nnkExprColonExpr.newTree(ident"name", newLit(fieldName)),
        nnkExprColonExpr.newTree(ident"keyLen", newLit(fieldName.len)),
        nnkExprColonExpr.newTree(ident"kind", kindNode)
      ))
  DecodeFieldPlanCache[info.key] = result

macro jsonDecodePlan*(T: typedesc): untyped =
  result = nnkObjConstr.newTree(
    bindSym"JsonDecodePlan",
    nnkExprColonExpr.newTree(ident"fields",
      nnkPrefix.newTree(ident"@", objectDecodePlanNode(T)))
  )

type FieldMeta = tuple[name: string, access: NimNode, kind: JsonSerializeFieldKind]

proc serializeFieldKindNode(fieldType: NimNode; isJsonSafePragma: bool): JsonSerializeFieldKind =
  if isJsonSafePragma:
    return jsfkJsonSafeString
  let typeInst = fieldType.getTypeInst
  if fieldType.kind in {nnkIdent, nnkSym}:
    if eqIdent(fieldType, "JsonSafeString"):
      return jsfkJsonSafeString
    if eqIdent(fieldType, "JsonAsciiSafeString"):
      return jsfkAsciiSafeString
  if typeInst.kind in {nnkIdent, nnkSym}:
    if eqIdent(typeInst, "JsonSafeString"):
      return jsfkJsonSafeString
    if eqIdent(typeInst, "JsonAsciiSafeString"):
      return jsfkAsciiSafeString
  jsfkGeneric

proc numericTreeDepthNode(typeNode: NimNode): int =
  let concrete = unwrapTypedescNodeLocal(typeNode)
  let typeInst = concrete.getTypeInst
  if concrete.kind == nnkBracketExpr and concrete.len >= 2:
    if eqIdent(concrete[0], "seq"):
      let child = numericTreeDepthNode(concrete[1])
      if child > 0:
        return child + 1
    elif eqIdent(concrete[0], "array") and concrete.len == 3:
      let child = numericTreeDepthNode(concrete[2])
      if child > 0:
        return child + 1
  case typeNode.typeKind
  of ntyFloat, ntyFloat32, ntyFloat64:
    return 1
  else:
    discard
  if typeInst.kind == nnkBracketExpr and typeInst.len >= 2:
    if eqIdent(typeInst[0], "seq"):
      let child = numericTreeDepthNode(typeInst[1])
      if child > 0:
        return child + 1
    elif eqIdent(typeInst[0], "array") and typeInst.len == 3:
      let child = numericTreeDepthNode(typeInst[2])
      if child > 0:
        return child + 1
  0

proc serializeRootShapeNode(typeNode: NimNode): NimNode =
  let concrete = unwrapTypedescNodeLocal(typeNode)
  let typeInst = concrete.getTypeInst
  if concrete.kind == nnkBracketExpr and concrete.len >= 2:
    if eqIdent(concrete[0], "seq"):
      let elemType = concrete[1]
      let elemRecList = supportedObjectRecListLocal(elemType)
      if elemRecList.kind == nnkRecList:
        return bindSym"jsrsSeqObject"
    elif concrete.len == 3 and (eqIdent(concrete[0], "Table") or eqIdent(concrete[0], "OrderedTable")):
      let keyType = concrete[1]
      let valueType = concrete[2]
      let valueRecList = supportedObjectRecListLocal(valueType)
      if valueRecList.kind == nnkRecList and keyType.kind in {nnkIdent, nnkSym} and eqIdent(keyType, "string"):
        return bindSym"jsrsTableObject"
  if typeInst.kind == nnkBracketExpr and typeInst.len >= 2:
    if eqIdent(typeInst[0], "seq"):
      let elemType = typeInst[1]
      let elemRecList = supportedObjectRecListLocal(elemType)
      if elemRecList.kind == nnkRecList:
        return bindSym"jsrsSeqObject"
    elif typeInst.len == 3 and (eqIdent(typeInst[0], "Table") or eqIdent(typeInst[0], "OrderedTable")):
      let keyType = typeInst[1]
      let valueType = typeInst[2]
      let valueRecList = supportedObjectRecListLocal(valueType)
      if valueRecList.kind == nnkRecList and keyType.kind in {nnkIdent, nnkSym} and eqIdent(keyType, "string"):
        return bindSym"jsrsTableObject"
  if numericTreeDepthNode(typeNode) >= 3:
    return bindSym"jsrsNumericTree"
  bindSym"jsrsGeneric"

macro selectedSerializeRootShape*(T: typedesc): untyped =
  serializeRootShapeNode(T)

proc objectFieldEntriesEx(value: NimNode): seq[FieldMeta] =
  ## Extended version that also detects {.jsonSafe.} pragma on fields.
  let info = objectTypeInfo(value)
  let plan = objectFieldPlanNode(value)
  # Build pragma lookup from the raw type impl
  var kindMap: seq[(string, JsonSerializeFieldKind)]
  for field in info.impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[^2]
    for idx in 0 ..< field.len - 2:
      let nameNode = field[idx]
      let fieldName = extractFieldName(nameNode)
      let safe = fieldNodeHasPragma(nameNode, "jsonSafe")
      kindMap.add((fieldName, serializeFieldKindNode(fieldType, safe)))
  # Merge plan entries with pragma info
  for entry in plan:
    let fieldName = entry[0].strVal
    var kind = jsfkGeneric
    for (pn, pk) in kindMap:
      if pn == fieldName:
        kind = pk
        break
    result.add((fieldName, nnkDotExpr.newTree(value, ident(fieldName)), kind))

proc strEqualsStatic(key: string, literal: static string): bool {.inline.} =
  ## Word-at-a-time string comparison with compile-time constant on the right side.
  ## Same approach as spanEquals but for heap strings (used in the escaped-key fallback path).
  if key.len != literal.len:
    return false
  when literal.len == 0:
    true
  elif literal.len == 1:
    key[0] == literal[0]
  elif literal.len <= 3:
    const expected = loadU32(literal, 0)
    var a: uint32
    copyMem(addr a, unsafeAddr key[0], literal.len)
    a == expected
  elif literal.len == 4:
    const expected = loadU32(literal, 0)
    var a: uint32
    copyMem(addr a, unsafeAddr key[0], 4)
    a == expected
  elif literal.len <= 7:
    const exp1 = loadU32(literal, 0)
    const exp2 = loadU32(literal, literal.len - 4)
    var a1, a2: uint32
    copyMem(addr a1, unsafeAddr key[0], 4)
    copyMem(addr a2, unsafeAddr key[literal.len - 4], 4)
    (a1 == exp1) and (a2 == exp2)
  elif literal.len == 8:
    const expected = loadU64(literal, 0)
    var a: uint64
    copyMem(addr a, unsafeAddr key[0], 8)
    a == expected
  elif literal.len <= 15:
    const exp1 = loadU64(literal, 0)
    const exp2 = loadU64(literal, literal.len - 8)
    var a1, a2: uint64
    copyMem(addr a1, unsafeAddr key[0], 8)
    copyMem(addr a2, unsafeAddr key[literal.len - 8], 8)
    (a1 == exp1) and (a2 == exp2)
  elif literal.len == 16:
    const exp1 = loadU64(literal, 0)
    const exp2 = loadU64(literal, 8)
    var a1, a2: uint64
    copyMem(addr a1, unsafeAddr key[0], 8)
    copyMem(addr a2, unsafeAddr key[8], 8)
    (a1 == exp1) and (a2 == exp2)
  else:
    key == literal

macro parseObjectFieldDispatch(value: typed, key: typed, s: typed, i: typed): untyped =
  var groups = initOrderedTable[int, seq[(string, NimNode)]]()
  for (fieldName, access) in objectFieldEntries(value):
    groups.mgetOrPut(fieldName.len, @[]).add((fieldName, access))

  result = nnkCaseStmt.newTree(newCall(bindSym"len", key))
  for keyLen, entries in groups.pairs:
    var branchBody: NimNode = nil
    if keyLen > 0:
      var firstGroups = initOrderedTable[char, seq[(string, NimNode)]]()
      for entry in entries:
        firstGroups.mgetOrPut(entry[0][0], @[]).add(entry)
      if firstGroups.len > 1:
        let firstCharExpr = nnkBracketExpr.newTree(key, newLit(0))
        branchBody = nnkCaseStmt.newTree(firstCharExpr)
        for firstChar, firstEntries in firstGroups.pairs:
          var firstBody: NimNode = nil
          for entry in firstEntries:
            let cond = newCall(bindSym"strEqualsStatic", key, newLit(entry[0]))
            let parseCall = newCall(bindSym"parseValue", s, i, entry[1])
            if firstBody.isNil:
              firstBody = nnkIfStmt.newTree(nnkElifBranch.newTree(cond, parseCall))
            else:
              firstBody.add(nnkElifBranch.newTree(cond, parseCall))
          firstBody.add(nnkElse.newTree(newCall(bindSym"skipJsonValue", s, i)))
          branchBody.add(nnkOfBranch.newTree(newLit(firstChar), firstBody))
        branchBody.add(nnkElse.newTree(newCall(bindSym"skipJsonValue", s, i)))
      else:
        for entry in entries:
          let cond = newCall(bindSym"strEqualsStatic", key, newLit(entry[0]))
          let parseCall = newCall(bindSym"parseValue", s, i, entry[1])
          if branchBody.isNil:
            branchBody = nnkIfStmt.newTree(nnkElifBranch.newTree(cond, parseCall))
          else:
            branchBody.add(nnkElifBranch.newTree(cond, parseCall))
        branchBody.add(nnkElse.newTree(newCall(bindSym"skipJsonValue", s, i)))
    else:
      for entry in entries:
        let cond = newCall(bindSym"strEqualsStatic", key, newLit(entry[0]))
        let parseCall = newCall(bindSym"parseValue", s, i, entry[1])
        if branchBody.isNil:
          branchBody = nnkIfStmt.newTree(nnkElifBranch.newTree(cond, parseCall))
        else:
          branchBody.add(nnkElifBranch.newTree(cond, parseCall))
      branchBody.add(nnkElse.newTree(newCall(bindSym"skipJsonValue", s, i)))
    result.add(nnkOfBranch.newTree(newLit(keyLen), branchBody))
  result.add(nnkElse.newTree(newCall(bindSym"skipJsonValue", s, i)))

type PerfectSig = tuple[p1, p2: int]

proc fieldSigAt(name: string, p: PerfectSig): int {.inline.} =
  ## Compile-time twin of the runtime signature expression (byte pair as a
  ## 16-bit word).
  let b1 = if p.p1 < name.len: ord(name[p.p1]) else: 0
  let b2 = if p.p2 < name.len: ord(name[p.p2]) else: 0
  b1 shl 8 or b2

proc findPerfectSig(names: seq[string], keyLen: int): PerfectSig =
  ## Search a byte-pair signature unique across all same-length names, so the
  ## generated dispatch can be a switch instead of a linear compare chain.
  if keyLen < 2:
    return (-1, -1)
  for p1 in 0 ..< keyLen:
    for p2 in 0 ..< keyLen:
      if p1 == p2: continue
      var seen: HashSet[int]
      var ok = true
      for nm in names:
        let sig = fieldSigAt(nm, (p1, p2))
        if sig in seen:
          ok = false
          break
        seen.incl(sig)
      if ok:
        return (p1, p2)
  (-1, -1)

proc perfectSigExpr(s: NimNode, keyStart: NimNode, p: PerfectSig): NimNode =
  let p1 = newLit(p.p1)
  let p2 = newLit(p.p2)
  quote do: (ord(`s`[`keyStart` + `p1`]) shl 8) or ord(`s`[`keyStart` + `p2`])

macro parseObjectFieldDispatchSpan(value: typed, s: typed, keyStart: typed, keyLen: typed, i: typed): untyped =
  var groups = initOrderedTable[int, seq[(string, NimNode)]]()
  for (fieldName, access) in objectFieldEntries(value):
    groups.mgetOrPut(fieldName.len, @[]).add((fieldName, access))

  result = nnkCaseStmt.newTree(keyLen)
  for fieldLen, entries in groups.pairs:
    var branchBody: NimNode = nil
    if fieldLen > 0:
      var firstGroups = initOrderedTable[char, seq[(string, NimNode)]]()
      for entry in entries:
        firstGroups.mgetOrPut(entry[0][0], @[]).add(entry)
      var names: seq[string] = @[]
      for entry in entries:
        names.add(entry[0])
      let ps = findPerfectSig(names, fieldLen)
      if entries.len >= 4 and ps.p1 >= 0:
        branchBody = nnkCaseStmt.newTree(perfectSigExpr(s, keyStart, ps))
        for entry in entries:
          let sig = fieldSigAt(entry[0], ps)
          let cond = newCall(bindSym"spanEquals", s, keyStart, keyLen, newLit(entry[0]))
          let parseCall = newCall(bindSym"parseValue", s, i, entry[1])
          var body = nnkIfStmt.newTree(nnkElifBranch.newTree(cond, parseCall),
              nnkElse.newTree(newCall(bindSym"skipUnknownJsonKey", s, keyStart, keyLen, i)))
          branchBody.add(nnkOfBranch.newTree(newLit(sig), body))
        branchBody.add(nnkElse.newTree(newCall(bindSym"skipUnknownJsonKey", s, keyStart, keyLen, i)))
      elif firstGroups.len > 1:
        let firstCharExpr = nnkBracketExpr.newTree(s, keyStart)
        branchBody = nnkCaseStmt.newTree(firstCharExpr)
        for firstChar, firstEntries in firstGroups.pairs:
          var firstBody: NimNode = nil
          for entry in firstEntries:
            let cond = newCall(bindSym"spanEquals", s, keyStart, keyLen, newLit(entry[0]))
            let parseCall = newCall(bindSym"parseValue", s, i, entry[1])
            if firstBody.isNil:
              firstBody = nnkIfStmt.newTree(nnkElifBranch.newTree(cond, parseCall))
            else:
              firstBody.add(nnkElifBranch.newTree(cond, parseCall))
          firstBody.add(nnkElse.newTree(newCall(bindSym"skipUnknownJsonKey", s, keyStart, keyLen, i)))
          branchBody.add(nnkOfBranch.newTree(newLit(firstChar), firstBody))
        branchBody.add(nnkElse.newTree(newCall(bindSym"skipUnknownJsonKey", s, keyStart, keyLen, i)))
      else:
        for entry in entries:
          let cond = newCall(bindSym"spanEquals", s, keyStart, keyLen, newLit(entry[0]))
          let parseCall = newCall(bindSym"parseValue", s, i, entry[1])
          if branchBody.isNil:
            branchBody = nnkIfStmt.newTree(nnkElifBranch.newTree(cond, parseCall))
          else:
            branchBody.add(nnkElifBranch.newTree(cond, parseCall))
        branchBody.add(nnkElse.newTree(newCall(bindSym"skipUnknownJsonKey", s, keyStart, keyLen, i)))
    else:
      for entry in entries:
        let cond = newCall(bindSym"spanEquals", s, keyStart, keyLen, newLit(entry[0]))
        let parseCall = newCall(bindSym"parseValue", s, i, entry[1])
        if branchBody.isNil:
          branchBody = nnkIfStmt.newTree(nnkElifBranch.newTree(cond, parseCall))
        else:
          branchBody.add(nnkElifBranch.newTree(cond, parseCall))
      branchBody.add(nnkElse.newTree(newCall(bindSym"skipUnknownJsonKey", s, keyStart, keyLen, i)))
    result.add(nnkOfBranch.newTree(newLit(fieldLen), branchBody))
  result.add(nnkElse.newTree(newCall(bindSym"skipUnknownJsonKey", s, keyStart, keyLen, i)))

## Parses a JSON object into a value object T.
proc parseValue*[T: object](s: string, i: var int, value: var T) =
  eatSpace(s, i)
  expectChar(s, i, '{')
  incJsonDepth()
  defer: decJsonDepth()
  eatSpace(s, i)
  if i < s.len and s[i] == '}':
    inc i
    return
  var key = ""
  var keyStart = 0
  var keyLen = 0
  while true:
    if parseObjectKeySpan(s, i, keyStart, keyLen):
      expectChar(s, i, ':')
      parseObjectFieldDispatchSpan(value, s, keyStart, keyLen, i)
    else:
      eatSpace(s, i)
      if i >= s.len or s[i] != '"':
        jsonError("object key must be a string", i)
      parseJsonString(s, i, key)
      expectChar(s, i, ':')
      parseObjectFieldDispatch(value, key, s, i)
    eatSpace(s, i)
    if i >= s.len:
      jsonError("unterminated object", i)
    if s[i] == '}':
      inc i
      return
    expectChar(s, i, ',')

const DigitPairs = block:
  var pairs: array[100, array[2, char]]
  for n in 0..99:
    pairs[n][0] = char(ord('0') + (n div 10))
    pairs[n][1] = char(ord('0') + (n mod 10))
  pairs

proc appendSpan(buf: var string, src: string, startIdx, spanLen: int) {.inline, used.} =
  if spanLen <= 0:
    return
  let outLen = buf.len
  buf.setLen(checkedJsonAdd(outLen, spanLen))
  copyMem(addr buf[outLen], unsafeAddr src[startIdx], spanLen)

  when defined(release):
    {.push checks: off, inline.}

const NeedsEscape: array[256, bool] = block:
  ## Lookup table: true if byte needs JSON escaping (", \, control chars < 0x20)
  var t: array[256, bool]
  for i in 0..31: t[i] = true
  t[ord('"')] = true
  t[ord('\\')] = true
  t

# ── JSON-safety scan: find first byte needing JSON escape ──
# Two backends: a portable SWAR (8 bytes/uint64) and an optional SSE2
# (nimsimd, 16 bytes/vector) selected by fastjsonScanUseSse2. The SSE2 kernel
# replaces the earlier {.emit.} SSE2/NEON regions (removed in 073cd40 for pure
# Nim) as cross-compiler nimsimd intrinsics. It wins on long safe spans and
# loses on escape-dense/short strings, so the choice is workload-dependent
# (docs/design/simd-adoption.md, git 073cd40/85747c7).

proc scanSafeJsonBytes(value: string, start: int): int {.inline.} =
  ## Find first byte needing JSON escape from `start`, or value.len if none.
  ## SSE2 (nimsimd) tests 16 bytes per vector when `fastjsonScanUseSse2`, else
  ## the portable SWAR tests 8 bytes per uint64; a scalar loop resolves the
  ## break chunk and the short tail. Unsafe = control byte (<0x20), quote, or
  ## backslash. Workload-dependent: wins on long safe spans, loses on dense.
  let vlen = value.len
  if vlen == 0: return 0
  var idx = start
  when fastjsonScanUseSse2:
    let qv = mm_set1_epi8(0x22.uint8)
    let sv = mm_set1_epi8(0x5c.uint8)
    let cv = mm_set1_epi8(0x1f.uint8)
    while idx + 16 <= vlen:
      let d = mm_loadu_si128(cast[ptr uint64](unsafeAddr value[idx]))
      let u = mm_or_si128(mm_or_si128(mm_cmpeq_epi8(d, qv), mm_cmpeq_epi8(d, sv)),
                          mm_cmpeq_epi8(mm_min_epu8(d, cv), d))
      var m = mm_movemask_epi8(u)
      if m != 0:
        var b = 0
        while (m and 1) == 0: m = m shr 1; inc b
        return idx + b
      idx += 16
  else:
    while idx + 8 <= vlen:
      var chunk: uint64
      copyMem(addr chunk, unsafeAddr value[idx], 8)
      if escChunkHit(chunk):
        break
      idx += 8
  while idx < vlen:
    if NeedsEscape[ord(value[idx])]:
      return idx
    inc idx
  vlen

proc copySafeJsonBytesFused(value: string, start: int, buf: var string, pos: var int): int {.inline, used.} =
  ## Copy safe bytes into the destination buffer until the next unsafe JSON
  ## byte, returning that index. One SWAR scan plus one memcpy; strings that
  ## fit in L1/L2 do not care whether the passes are fused.
  let vlen = value.len
  if start >= vlen:
    return start
  result = scanSafeJsonBytes(value, start)
  let safeLen = result - start
  if safeLen > 0:
    copyMem(addr buf[pos], unsafeAddr value[start], safeLen)
    pos += safeLen

# Legacy alias used by serializer staging paths; always uses the Nim scanner.
proc nextUnsafeJsonByte(value: string, start: int): int {.inline.} =
  scanSafeJsonBytes(value, start)

proc appendFloatDirect(buf: var string, value: float64) {.inline.} =
  if value != value:
    raise newException(JsonError, "NaN cannot be represented in JSON (RFC 8259 §6)")
  if value == Inf or value == NegInf:
    raise newException(JsonError, "Infinity cannot be represented in JSON (RFC 8259 §6)")
  var fbuf {.noinit.}: array[65, char]
  let n = toChars(fbuf, value, forceTrailingDotZero = true).int
  let oldLen = buf.len
  buf.setLen(checkedJsonAdd(oldLen, n))
  copyMem(addr buf[oldLen], addr fbuf[0], n)

const DigitTriples = ["000","001","002","003","004","005","006","007","008","009","010","011","012","013","014","015","016","017","018","019","020","021","022","023","024","025","026","027","028","029","030","031","032","033","034","035","036","037","038","039","040","041","042","043","044","045","046","047","048","049","050","051","052","053","054","055","056","057","058","059","060","061","062","063","064","065","066","067","068","069","070","071","072","073","074","075","076","077","078","079","080","081","082","083","084","085","086","087","088","089","090","091","092","093","094","095","096","097","098","099","100","101","102","103","104","105","106","107","108","109","110","111","112","113","114","115","116","117","118","119","120","121","122","123","124","125","126","127","128","129","130","131","132","133","134","135","136","137","138","139","140","141","142","143","144","145","146","147","148","149","150","151","152","153","154","155","156","157","158","159","160","161","162","163","164","165","166","167","168","169","170","171","172","173","174","175","176","177","178","179","180","181","182","183","184","185","186","187","188","189","190","191","192","193","194","195","196","197","198","199","200","201","202","203","204","205","206","207","208","209","210","211","212","213","214","215","216","217","218","219","220","221","222","223","224","225","226","227","228","229","230","231","232","233","234","235","236","237","238","239","240","241","242","243","244","245","246","247","248","249","250","251","252","253","254","255","256","257","258","259","260","261","262","263","264","265","266","267","268","269","270","271","272","273","274","275","276","277","278","279","280","281","282","283","284","285","286","287","288","289","290","291","292","293","294","295","296","297","298","299","300","301","302","303","304","305","306","307","308","309","310","311","312","313","314","315","316","317","318","319","320","321","322","323","324","325","326","327","328","329","330","331","332","333","334","335","336","337","338","339","340","341","342","343","344","345","346","347","348","349","350","351","352","353","354","355","356","357","358","359","360","361","362","363","364","365","366","367","368","369","370","371","372","373","374","375","376","377","378","379","380","381","382","383","384","385","386","387","388","389","390","391","392","393","394","395","396","397","398","399","400","401","402","403","404","405","406","407","408","409","410","411","412","413","414","415","416","417","418","419","420","421","422","423","424","425","426","427","428","429","430","431","432","433","434","435","436","437","438","439","440","441","442","443","444","445","446","447","448","449","450","451","452","453","454","455","456","457","458","459","460","461","462","463","464","465","466","467","468","469","470","471","472","473","474","475","476","477","478","479","480","481","482","483","484","485","486","487","488","489","490","491","492","493","494","495","496","497","498","499","500","501","502","503","504","505","506","507","508","509","510","511","512","513","514","515","516","517","518","519","520","521","522","523","524","525","526","527","528","529","530","531","532","533","534","535","536","537","538","539","540","541","542","543","544","545","546","547","548","549","550","551","552","553","554","555","556","557","558","559","560","561","562","563","564","565","566","567","568","569","570","571","572","573","574","575","576","577","578","579","580","581","582","583","584","585","586","587","588","589","590","591","592","593","594","595","596","597","598","599","600","601","602","603","604","605","606","607","608","609","610","611","612","613","614","615","616","617","618","619","620","621","622","623","624","625","626","627","628","629","630","631","632","633","634","635","636","637","638","639","640","641","642","643","644","645","646","647","648","649","650","651","652","653","654","655","656","657","658","659","660","661","662","663","664","665","666","667","668","669","670","671","672","673","674","675","676","677","678","679","680","681","682","683","684","685","686","687","688","689","690","691","692","693","694","695","696","697","698","699","700","701","702","703","704","705","706","707","708","709","710","711","712","713","714","715","716","717","718","719","720","721","722","723","724","725","726","727","728","729","730","731","732","733","734","735","736","737","738","739","740","741","742","743","744","745","746","747","748","749","750","751","752","753","754","755","756","757","758","759","760","761","762","763","764","765","766","767","768","769","770","771","772","773","774","775","776","777","778","779","780","781","782","783","784","785","786","787","788","789","790","791","792","793","794","795","796","797","798","799","800","801","802","803","804","805","806","807","808","809","810","811","812","813","814","815","816","817","818","819","820","821","822","823","824","825","826","827","828","829","830","831","832","833","834","835","836","837","838","839","840","841","842","843","844","845","846","847","848","849","850","851","852","853","854","855","856","857","858","859","860","861","862","863","864","865","866","867","868","869","870","871","872","873","874","875","876","877","878","879","880","881","882","883","884","885","886","887","888","889","890","891","892","893","894","895","896","897","898","899","900","901","902","903","904","905","906","907","908","909","910","911","912","913","914","915","916","917","918","919","920","921","922","923","924","925","926","927","928","929","930","931","932","933","934","935","936","937","938","939","940","941","942","943","944","945","946","947","948","949","950","951","952","953","954","955","956","957","958","959","960","961","962","963","964","965","966","967","968","969","970","971","972","973","974","975","976","977","978","979","980","981","982","983","984","985","986","987","988","989","990","991","992","993","994","995","996","997","998","999"]

proc appendIntFast[T: SomeInteger](buf: var string, value: T) {.inline.} =
  when T is SomeSignedInt:
    if value < 0:
      buf.add($value)
      return
  var raw = uint64(value)
  var digits: array[32, char]
  var pos = digits.len
  var current = raw
  if current == 0:
    dec pos
    digits[pos] = '0'
  else:
    # Three-digit chunks: one div/mod pair per 3 digits instead of per 2,
    # which cuts the expensive integer division count for typical values.
    while current >= 1000:
      let chunk = int(current mod 1000)
      current = current div 1000
      pos -= 3
      digits[pos] = DigitTriples[chunk][0]
      digits[pos + 1] = DigitTriples[chunk][1]
      digits[pos + 2] = DigitTriples[chunk][2]
    if current < 10:
      dec pos
      digits[pos] = char(ord('0') + int(current))
    elif current < 100:
      pos -= 2
      digits[pos] = char(ord('0') + int(current div 10))
      digits[pos + 1] = char(ord('0') + int(current mod 10))
    else:
      pos -= 3
      digits[pos] = char(ord('0') + int(current div 100))
      digits[pos + 1] = char(ord('0') + int((current div 10) mod 10))
      digits[pos + 2] = char(ord('0') + int(current mod 10))
  let outLen = buf.len
  let copyLen = digits.len - pos
  buf.setLen(checkedJsonAdd(outLen, copyLen))
  copyMem(addr buf[outLen], addr digits[pos], copyLen)

# === Cursor-based write functions ===
# These write into a pre-allocated buffer via a `pos` cursor,
# avoiding per-element setLen calls. The buffer must have been
# pre-allocated with setLen(capacity) before calling these.

proc ensureRoom(buf: var string, pos, needed: int) {.inline, used.} =
  ## Grow buffer if pos + needed exceeds current length.
  if pos < 0 or needed < 0 or pos > high(int) - needed:
    raise newException(JsonError, "JSON output too large to serialize")
  let required = pos + needed
  if required > buf.len:
    var grown = required
    let extra = checkedJsonAdd(required shr 2, 64)
    if grown <= high(int) - extra:
      grown += extra
    buf.setLen(grown)

proc cPut(buf: var string, pos: var int, c: char) {.inline, used.} =
  buf[pos] = c
  inc pos

proc cPutStr(buf: var string, pos: var int, s: string) {.inline.} =
  if s.len > 0:
    copyMem(addr buf[pos], unsafeAddr s[0], s.len)
    pos += s.len

proc cPutLit(buf: var string, pos: var int, s: static string) {.inline.} =
  ## Write a compile-time string using embedded integer constants.
  ## Avoids {.global.} TLS overhead by encoding bytes as compile-time uint64s.
  when s.len == 0:
    discard
  elif s.len <= 8:
    const w = loadU64(s, 0)
    var v = w
    copyMem(addr buf[pos], addr v, s.len)
    pos += s.len
  elif s.len <= 16:
    const w1 = loadU64(s, 0)
    const w2 = loadU64(s, s.len - 8)
    var v1 = w1
    var v2 = w2
    copyMem(addr buf[pos], addr v1, 8)
    copyMem(addr buf[pos + s.len - 8], addr v2, 8)
    pos += s.len
  else:
    # 17+ bytes: use a local copy (rare for field name prefixes)
    var lit {.noinit.}: array[s.len, char]
    for ci in 0 ..< s.len:
      lit[ci] = s[ci]
    copyMem(addr buf[pos], addr lit[0], s.len)
    pos += s.len

proc cPutFloat(buf: var string, pos: var int, value: float64) {.inline.} =
  if value != value:
    raise newException(JsonError, "NaN cannot be represented in JSON (RFC 8259 §6)")
  if value == Inf or value == NegInf:
    raise newException(JsonError, "Infinity cannot be represented in JSON (RFC 8259 §6)")
  let p = cast[ptr array[65, char]](addr buf[pos])
  let n = toChars(p[], value, forceTrailingDotZero = true).int
  pos += n

proc cPutInt[T: SomeInteger](buf: var string, pos: var int, value: T) {.inline.} =
  when T is SomeSignedInt:
    if value < 0:
      let s = $value
      cPutStr(buf, pos, s)
      return
  var raw = uint64(value)
  var digits: array[32, char]
  var dpos = digits.len
  var current = raw
  if current == 0:
    dec dpos
    digits[dpos] = '0'
  else:
    while current >= 100:
      let pair = int(current mod 100)
      current = current div 100
      dpos -= 2
      digits[dpos] = DigitPairs[pair][0]
      digits[dpos + 1] = DigitPairs[pair][1]
    if current < 10:
      dec dpos
      digits[dpos] = char(ord('0') + int(current))
    else:
      dpos -= 2
      digits[dpos] = DigitPairs[int(current)][0]
      digits[dpos + 1] = DigitPairs[int(current)][1]
  let copyLen = digits.len - dpos
  copyMem(addr buf[pos], addr digits[dpos], copyLen)
  pos += copyLen

const EscapeSeq = block:
  ## Pre-built escape sequences indexed by byte value.
  ## Each entry is 6 bytes (padded) + 1 byte length.
  var seqs: array[256, array[8, char]]
  var lens: array[256, uint8]
  for i in 0..255:
    let ch = char(i)
    if ch == '"':
      seqs[i] = ['\\', '"', '\0', '\0', '\0', '\0', '\0', '\0']
      lens[i] = 2
    elif ch == '\\':
      seqs[i] = ['\\', '\\', '\0', '\0', '\0', '\0', '\0', '\0']
      lens[i] = 2
    elif ch == '\b':
      seqs[i] = ['\\', 'b', '\0', '\0', '\0', '\0', '\0', '\0']
      lens[i] = 2
    elif ch == '\f':
      seqs[i] = ['\\', 'f', '\0', '\0', '\0', '\0', '\0', '\0']
      lens[i] = 2
    elif ch == '\n':
      seqs[i] = ['\\', 'n', '\0', '\0', '\0', '\0', '\0', '\0']
      lens[i] = 2
    elif ch == '\r':
      seqs[i] = ['\\', 'r', '\0', '\0', '\0', '\0', '\0', '\0']
      lens[i] = 2
    elif ch == '\t':
      seqs[i] = ['\\', 't', '\0', '\0', '\0', '\0', '\0', '\0']
      lens[i] = 2
    elif i < 0x20:
      let h1 = "0123456789abcdef"[(i shr 4) and 0x0f]
      let h2 = "0123456789abcdef"[i and 0x0f]
      seqs[i] = ['\\', 'u', '0', '0', h1, h2, '\0', '\0']
      lens[i] = 6
    else:
      seqs[i] = [ch, '\0', '\0', '\0', '\0', '\0', '\0', '\0']
      lens[i] = 1
  (seqs: seqs, lens: lens)

proc worstJsonStringBytes(vlen: int, extraBytes: int): int {.inline.} =
  checkedJsonAdd(checkedJsonMul(vlen, 6, "JSON string too large to serialize"),
    extraBytes, "JSON string too large to serialize")

proc appendJsonEscapedSlow(buf: var string, value: string, firstUnsafe: int) =
  # Full escaped path for strings that contain unsafe bytes.
  # firstUnsafe is the already-known position of the first unsafe byte.
  let baseLen = buf.len
  let worstCase = worstJsonStringBytes(value.len, 2)
  buf.setLen(checkedJsonAdd(baseLen, worstCase))
  var dst = baseLen
  buf[dst] = '"'; inc dst

  # Copy safe prefix
  if firstUnsafe > 0:
    copyMem(addr buf[dst], unsafeAddr value[0], firstUnsafe)
    dst += firstUnsafe
  # Escape the first unsafe byte
  var i = firstUnsafe
  let b0 = ord(value[i])
  let escLen0 = int(EscapeSeq.lens[b0])
  var esc0 = EscapeSeq.seqs[b0]
  let requiredEsc0 = checkedJsonAdd(dst, escLen0)
  if requiredEsc0 > buf.len:
    buf.setLen(requiredEsc0)
  copyMem(addr buf[dst], addr esc0[0], escLen0)
  dst += escLen0
  i += 1

  while i < value.len:
    let unsafeAt = nextUnsafeJsonByte(value, i)
    let safeLen = unsafeAt - i
    if safeLen > 0:
      let requiredSafe = checkedJsonAdd(dst, safeLen)
      if requiredSafe > buf.len:
        buf.setLen(requiredSafe)
      copyMem(addr buf[dst], unsafeAddr value[i], safeLen)
      dst += safeLen
    if unsafeAt >= value.len:
      break
    let b = ord(value[unsafeAt])
    let escLen = int(EscapeSeq.lens[b])
    let requiredEsc = checkedJsonAdd(dst, escLen)
    if requiredEsc > buf.len:
      buf.setLen(requiredEsc)
    var esc = EscapeSeq.seqs[b]
    copyMem(addr buf[dst], addr esc[0], escLen)
    dst += escLen
    i = unsafeAt + 1

  buf[dst] = '"'; inc dst
  buf.setLen(dst)

proc appendJsonEscaped(buf: var string, value: string) =
  # Fast path: SWAR-scan entire string for safety. Most real-world JSON strings
  # have no escapes, so we can skip the escape loop and do a single copyMem.
  # Passes firstUnsafe to slow path to avoid re-scanning the safe prefix.
  let vlen = value.len
  if vlen == 0:
    buf.add("\"\"")
    return
  let unsafeAt = nextUnsafeJsonByte(value, 0)
  if unsafeAt >= vlen:
    # Entire string is safe — one setLen + copyMem
    let baseLen = buf.len
    buf.setLen(checkedJsonAdd(baseLen, checkedJsonAdd(vlen, 2, "JSON string too large to serialize")))
    buf[baseLen] = '"'
    copyMem(addr buf[baseLen + 1], unsafeAddr value[0], vlen)
    buf[baseLen + 1 + vlen] = '"'
    return
  appendJsonEscapedSlow(buf, value, unsafeAt)

proc cPutJsonEscapedSlow(buf: var string, pos: var int, value: string, vlen: int, firstUnsafe: int) {.used.} =
  ## Slow path for strings with known unsafe bytes.
  ## firstUnsafe is the already-known position of the first unsafe byte,
  ## so we can copy the safe prefix without re-scanning.
  ## Uses inline scalar scan for short remaining spans, SIMD for longer ones.
  ensureRoom(buf, pos, worstJsonStringBytes(vlen, 2))
  buf[pos] = '"'; inc pos
  # Copy safe prefix up to firstUnsafe
  if firstUnsafe > 0:
    copyMem(addr buf[pos], unsafeAddr value[0], firstUnsafe)
    pos += firstUnsafe
  # Escape the first unsafe byte
  var i = firstUnsafe
  let b0 = ord(value[i])
  let escLen0 = int(EscapeSeq.lens[b0])
  var esc0 = EscapeSeq.seqs[b0]
  copyMem(addr buf[pos], addr esc0[0], escLen0)
  pos += escLen0
  i += 1
  # Continue scanning: SIMD/SWAR scan to find next unsafe, batch-copy safe spans
  while i < vlen:
    let scanIdx = scanSafeJsonBytes(value, i)
    let safeLen = scanIdx - i
    if safeLen > 0:
      copyMem(addr buf[pos], unsafeAddr value[i], safeLen)
      pos += safeLen
    if scanIdx >= vlen:
      break
    let b = ord(value[scanIdx])
    let escLen = int(EscapeSeq.lens[b])
    var esc = EscapeSeq.seqs[b]
    copyMem(addr buf[pos], addr esc[0], escLen)
    pos += escLen
    i = scanIdx + 1
  buf[pos] = '"'; inc pos

proc swarNeedsEscape8(p: pointer): bool {.inline.} =
  var chunk: uint64
  copyMem(addr chunk, p, 8)
  (chunk and ByteHighBits) != 0'u64 or
    hasZeroByte(chunk xor QuoteMask) or
    hasZeroByte(chunk xor SlashMask) or
    ((chunk - ControlFloor) and (not chunk) and ByteHighBits) != 0'u64

proc cPutJsonEscaped(buf: var string, pos: var int, value: string) {.inline.} =
  let vlen = value.len
  ensureRoom(buf, pos, worstJsonStringBytes(vlen, 2))
  if vlen == 0:
    buf[pos] = '"'; buf[pos + 1] = '"'
    pos += 2
    return
  if vlen <= 16:
    var allSafe = true
    let vPtr = unsafeAddr value[0]
    if vlen >= 8:
      if swarNeedsEscape8(vPtr):
        allSafe = false
      elif vlen > 8 and swarNeedsEscape8(cast[pointer](cast[uint](vPtr) + uint(vlen - 8))):
        allSafe = false
    else:
      var ci = 0
      while ci < vlen:
        if NeedsEscape[ord(value[ci])]:
          allSafe = false
          break
        inc ci
    if allSafe:
      buf[pos] = '"'
      copyMem(addr buf[pos + 1], unsafeAddr value[0], vlen)
      buf[pos + 1 + vlen] = '"'
      pos += vlen + 2
      return
  # Full path: SIMD scan + copy loop
  buf[pos] = '"'; inc pos
  var i = 0
  while i < vlen:
    let safe = scanSafeJsonBytes(value, i)
    let safeLen = safe - i
    if safeLen > 0:
      copyMem(addr buf[pos], unsafeAddr value[i], safeLen)
      pos += safeLen
    if safe >= vlen:
      break
    ensureRoom(buf, pos, 8)
    let b = ord(value[safe])
    let escLen = int(EscapeSeq.lens[b])
    var esc = EscapeSeq.seqs[b]
    copyMem(addr buf[pos], addr esc[0], escLen)
    pos += escLen
    i = safe + 1
  buf[pos] = '"'; inc pos

proc cPutStrUnescaped(buf: var string, pos: var int, value: string) {.inline.} =
  ## Write a JSON string WITHOUT escape scanning — for {.jsonSafe.} fields.
  ## Just writes: "rawcopy"
  let vlen = value.len
  ensureRoom(buf, pos, vlen + 2)
  buf[pos] = '"'
  if vlen > 0:
    copyMem(addr buf[pos + 1], unsafeAddr value[0], vlen)
  buf[pos + 1 + vlen] = '"'
  pos += vlen + 2

proc cPutJsonBodySlow(buf: var string, pos: var int, value: string, vlen: int) =
  ## Slow path for strings that need escaping or are long: SWAR-scanned safe
  ## spans copied with memcpy, escape bytes written from the EscapeSeq table.
  ensureRoom(buf, pos, worstJsonStringBytes(vlen, 1))
  var i = 0
  while i < vlen:
    let safe = copySafeJsonBytesFused(value, i, buf, pos)
    if safe >= vlen:
      break
    ensureRoom(buf, pos, 8)
    let b = ord(value[safe])
    let escLen = int(EscapeSeq.lens[b])
    var esc = EscapeSeq.seqs[b]
    copyMem(addr buf[pos], addr esc[0], escLen)
    pos += escLen
    i = safe + 1
  buf[pos] = '"'
  inc pos

proc cPutJsonBody(buf: var string, pos: var int, value: string) {.inline.} =
  let vlen = value.len
  ensureRoom(buf, pos, worstJsonStringBytes(vlen, 1))
  if vlen == 0:
    buf[pos] = '"'; inc pos
    return
  if vlen <= 16:
    var allSafe = true
    let vPtr = unsafeAddr value[0]
    if vlen >= 8:
      if swarNeedsEscape8(vPtr):
        allSafe = false
      elif vlen > 8 and swarNeedsEscape8(cast[pointer](cast[uint](vPtr) + uint(vlen - 8))):
        allSafe = false
    else:
      var ci = 0
      while ci < vlen:
        if NeedsEscape[ord(value[ci])]:
          allSafe = false
          break
        inc ci
    if allSafe:
      copyMem(addr buf[pos], unsafeAddr value[0], vlen)
      pos += vlen
      buf[pos] = '"'; inc pos
      return
  cPutJsonBodySlow(buf, pos, value, vlen)

proc cPutStrUnescapedBody(buf: var string, pos: var int, value: string) {.inline.} =
  ## Write string body + closing quote without escaping. No opening quote.
  ## For {.jsonSafe.} fields with fused prefix.
  let vlen = value.len
  ensureRoom(buf, pos, vlen + 1)
  if vlen > 0:
    copyMem(addr buf[pos], unsafeAddr value[0], vlen)
    pos += vlen
  buf[pos] = '"'; inc pos

proc writeValue[T](buf: var string, value: seq[T])
proc writeValue(buf: var string, value: seq[string])
proc writeValue(buf: var string, value: seq[JsonSafeString])
proc writeValue(buf: var string, value: seq[JsonAsciiSafeString])
proc writeValue[T: object](buf: var string, value: seq[T])
proc writeValue[T: ref object](buf: var string, value: T)
proc writeValue[T: object](buf: var string, value: T)
proc writeValue(buf: var string, value: bool)
proc writeValue[T: SomeInteger](buf: var string, value: T)
proc writeValue[T: SomeFloat](buf: var string, value: T)
proc writeValue(buf: var string, value: string)
proc writeValue(buf: var string, value: JsonSafeString)
proc writeValue(buf: var string, value: JsonAsciiSafeString)
proc writeValue(buf: var string, value: BorrowedString)
proc writeValue[T: enum](buf: var string, value: T)

proc estimateJsonSize[T](value: seq[T]): int
proc estimateJsonSize(value: seq[string]): int
proc estimateJsonSize(value: seq[JsonSafeString]): int
proc estimateJsonSize(value: seq[JsonAsciiSafeString]): int
proc estimateJsonSize[T: object](value: seq[T]): int
proc estimateJsonSize[T: ref object](value: T): int
proc estimateJsonSize[T: object](value: T): int
proc estimateJsonSize(value: bool): int
proc estimateJsonSize[T: SomeInteger](value: T): int
proc estimateJsonSize[T: SomeFloat](value: T): int
proc estimateJsonSize(value: string): int
proc estimateJsonSize(value: JsonSafeString): int
proc estimateJsonSize(value: JsonAsciiSafeString): int
proc estimateJsonSize(value: BorrowedString): int
proc estimateJsonSize[T: enum](value: T): int
proc estimateJsonSize[T](value: Option[T]): int
proc estimateJsonSize[A, B](value: Table[A, B]): int
proc estimateJsonSize[A, B](value: OrderedTable[A, B]): int

macro writeObjectFields(buf: typed, value: typed): untyped =
  result = newStmtList()
  var first = true
  let plan = objectFieldPlanNode(value)
  for entry in plan:
    let fieldName = entry[0].strVal
    let access = nnkDotExpr.newTree(value, ident(fieldName))
    # Batch comma + field name into a single literal
    let prefix = if first: "\"" & fieldName & "\":" else: ",\"" & fieldName & "\":"
    first = false
    result.add(newCall(bindSym"add", buf, newLit(prefix)))
    result.add(quote do:
      when typeof(`access`) is string:
        appendJsonEscaped(`buf`, `access`)
      elif typeof(`access`) is bool:
        if `access`:
          `buf`.add("true")
        else:
          `buf`.add("false")
      elif typeof(`access`) is SomeInteger:
        appendIntFast(`buf`, `access`)
      elif typeof(`access`) is SomeFloat:
        appendFloatDirect(`buf`, `access`)
      elif typeof(`access`) is seq[string]:
        `buf`.add('[')
        var idx = 0
        while idx < `access`.len:
          if idx > 0:
            `buf`.add(',')
          appendJsonEscaped(`buf`, `access`[idx])
          inc idx
        `buf`.add(']')
      else:
        writeValue(`buf`, `access`)
    )

macro typeStaticJsonOverhead(value: typed): int =
  ## Compile-time constant: sum of all field-name overhead + fixed-size field estimates.
  ## This avoids re-adding field name lengths at runtime on every serialize call.
  let info = objectTypeInfo(value)
  if StaticOverheadCache.hasKey(info.key):
    return StaticOverheadCache[info.key]
  var overhead = 2  # { }
  var first = true
  for field in info.impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    for idx in 0 ..< field.len - 2:
      if not first:
        overhead += 1  # comma separator
      first = false
      let fieldName = extractFieldName(field[idx])
      overhead += fieldName.len + 3  # "fieldName":
      # Add fixed estimate for non-variable-length types
      let fieldType = field[^2]
      if fieldType.kind == nnkSym:
        if eqIdent(fieldType, "int") or eqIdent(fieldType, "int64") or
            eqIdent(fieldType, "int32") or eqIdent(fieldType, "int16") or
            eqIdent(fieldType, "int8") or eqIdent(fieldType, "uint") or
            eqIdent(fieldType, "uint64") or eqIdent(fieldType, "uint32") or
            eqIdent(fieldType, "uint16") or eqIdent(fieldType, "uint8"):
          overhead += 8  # avg int width
        elif eqIdent(fieldType, "float64") or eqIdent(fieldType, "float32") or
            eqIdent(fieldType, "float"):
          overhead += 16  # avg float width
        elif eqIdent(fieldType, "bool"):
          overhead += 5  # worst case "false"
  let lit = newLit(overhead)
  StaticOverheadCache[info.key] = lit
  return lit

macro estimateDynamicFields(total: typed, value: typed): untyped =
  ## Only computes the variable-size parts: string lengths, seq sizes.
  ## Fixed-size fields (int, float, bool) are already in typeStaticJsonOverhead.
  result = newStmtList()
  let info = objectTypeInfo(value)
  for field in info.impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    for idx in 0 ..< field.len - 2:
      let fieldName = extractFieldName(field[idx])
      let access = nnkDotExpr.newTree(value, ident(fieldName))
      let fieldType = field[^2]
      var isFixed = false
      if fieldType.kind == nnkSym:
        if eqIdent(fieldType, "int") or eqIdent(fieldType, "int64") or
            eqIdent(fieldType, "int32") or eqIdent(fieldType, "int16") or
            eqIdent(fieldType, "int8") or eqIdent(fieldType, "uint") or
            eqIdent(fieldType, "uint64") or eqIdent(fieldType, "uint32") or
            eqIdent(fieldType, "uint16") or eqIdent(fieldType, "uint8") or
            eqIdent(fieldType, "float64") or eqIdent(fieldType, "float32") or
            eqIdent(fieldType, "float") or eqIdent(fieldType, "bool"):
          isFixed = true
      if not isFixed:
        result.add(quote do:
          when typeof(`access`) is string:
            `total` += max(2, `access`.len + 2)
          elif typeof(`access`) is seq[string]:
            if `access`.len == 0:
              `total` += 2
            else:
              `total` += 2 + (`access`.len - 1)
              var idx = 0
              while idx < `access`.len:
                `total` += max(2, `access`[idx].len + 2)
                inc idx
          else:
            `total` += estimateJsonSize(`access`)
        )

# Keep the old macro for backward compatibility with writeObjectFields (non-cursor path)
macro estimateObjectFields(total: typed, value: typed): untyped {.used.} =
  result = newStmtList()
  var first = true
  let plan = objectFieldPlanNode(value)
  for entry in plan:
    let fieldName = entry[0].strVal
    let access = nnkDotExpr.newTree(value, ident(fieldName))
    if not first:
      result.add(newCall(bindSym"inc", total))
    first = false
    result.add(newCall(bindSym"+=", total, newLit(fieldName.len + 3)))
    result.add(quote do:
      when typeof(`access`) is string:
        `total` += max(2, `access`.len + 2)
      elif typeof(`access`) is bool:
        `total` += (if `access`: 4 else: 5)
      elif typeof(`access`) is SomeInteger or typeof(`access`) is SomeFloat:
        `total` += 24
      elif typeof(`access`) is seq[string]:
        if `access`.len == 0:
          `total` += 2
        else:
          `total` += 2 + (`access`.len - 1)
          var idx = 0
          while idx < `access`.len:
            `total` += max(2, `access`[idx].len + 2)
            inc idx
      else:
        `total` += estimateJsonSize(`access`)
    )

proc writeValue(buf: var string, value: bool) =
  if value:
    buf.add("true")
  else:
    buf.add("false")

proc writeValue[T: SomeInteger](buf: var string, value: T) =
  appendIntFast(buf, value)

proc writeValue[T: SomeFloat](buf: var string, value: T) =
  appendFloatDirect(buf, float64(value))

proc writeValue(buf: var string, value: string) =
  appendJsonEscaped(buf, value)

proc writeValue(buf: var string, value: JsonSafeString) =
  buf.add('"')
  buf.add(rawString(value))
  buf.add('"')

proc writeValue(buf: var string, value: JsonAsciiSafeString) =
  buf.add('"')
  buf.add(rawString(value))
  buf.add('"')

proc writeValue(buf: var string, value: BorrowedString) =
  if value.isNil:
    buf.add("\"\"")
  else:
    let vlen = value.len
    if vlen == 0:
      buf.add("\"\"")
    else:
      let baseLen = buf.len
      buf.setLen(checkedJsonAdd(baseLen, checkedJsonAdd(vlen, 2,
        "JSON string too large to serialize")))
      buf[baseLen] = '"'
      copyMem(addr buf[baseLen + 1], value.dataPtr, vlen)
      buf[baseLen + 1 + vlen] = '"'
      var needsEscape = false
      for ci in 0 ..< vlen:
        let ch = buf[baseLen + 1 + ci]
        if ch == '"' or ch == '\\' or ord(ch) < 0x20:
          needsEscape = true
          break
      if needsEscape:
        buf.setLen(baseLen)
        appendJsonEscaped(buf, value.toString())

proc writeValue[T: enum](buf: var string, value: T) =
  appendJsonEscaped(buf, $value)

proc writeValue[T](buf: var string, value: seq[T]) =
  buf.add('[')
  var idx = 0
  while idx < value.len:
    if idx > 0:
      buf.add(',')
    writeValue(buf, value[idx])
    inc idx
  buf.add(']')

proc writeValue(buf: var string, value: seq[string]) =
  buf.add('[')
  if value.len > 0:
    let items = cast[ptr UncheckedArray[string]](unsafeAddr value[0])
    var idx = 0
    while idx < value.len:
      if idx > 0:
        buf.add(',')
      appendJsonEscaped(buf, items[idx])
      inc idx
  buf.add(']')

proc writeValue(buf: var string, value: seq[JsonSafeString]) =
  buf.add('[')
  if value.len > 0:
    let items = cast[ptr UncheckedArray[JsonSafeString]](unsafeAddr value[0])
    var idx = 0
    while idx < value.len:
      if idx > 0:
        buf.add(',')
      buf.add('"')
      buf.add(rawString(items[idx]))
      buf.add('"')
      inc idx
  buf.add(']')

proc writeValue(buf: var string, value: seq[JsonAsciiSafeString]) =
  buf.add('[')
  if value.len > 0:
    let items = cast[ptr UncheckedArray[JsonAsciiSafeString]](unsafeAddr value[0])
    var idx = 0
    while idx < value.len:
      if idx > 0:
        buf.add(',')
      buf.add('"')
      buf.add(rawString(items[idx]))
      buf.add('"')
      inc idx
  buf.add(']')

proc writeValue[T: object](buf: var string, value: seq[T]) =
  buf.add('[')
  if value.len > 0:
    let items = cast[ptr UncheckedArray[T]](unsafeAddr value[0])
    var idx = 0
    while idx < value.len:
      if idx > 0:
        buf.add(',')
      buf.add('{')
      writeObjectFields(buf, items[idx])
      buf.add('}')
      inc idx
  buf.add(']')

proc estimateJsonSize(value: seq[string]): int =
  if value.len == 0:
    return 2
  if value.len <= 8:
    result = 2
    let items = cast[ptr UncheckedArray[string]](unsafeAddr value[0])
    var idx = 0
    while idx < value.len:
      if idx > 0:
        result = checkedJsonAdd(result, 1)
      result = checkedJsonAdd(result, max(2, checkedJsonAdd(items[idx].len, 2,
        "JSON string too large to serialize")))
      inc idx
    return

  let firstSample = max(2, checkedJsonAdd(value[0].len, 2, "JSON string too large to serialize"))
  let lastSample = max(2, checkedJsonAdd(value[^1].len, 2, "JSON string too large to serialize"))
  let sample = max(8, checkedJsonAdd(firstSample, lastSample) shr 1)
  result = checkedJsonAdd(2, checkedJsonAdd(value.len - 1, checkedJsonMul(sample, value.len)))

proc estimateJsonSize(value: seq[JsonSafeString]): int =
  if value.len == 0:
    return 2
  result = checkedJsonAdd(2, value.len - 1)
  let items = cast[ptr UncheckedArray[JsonSafeString]](unsafeAddr value[0])
  var idx = 0
  while idx < value.len:
    result = checkedJsonAdd(result, max(2, checkedJsonAdd(rawString(items[idx]).len, 2,
      "JSON string too large to serialize")))
    inc idx

proc estimateJsonSize(value: seq[JsonAsciiSafeString]): int =
  if value.len == 0:
    return 2
  result = checkedJsonAdd(2, value.len - 1)
  let items = cast[ptr UncheckedArray[JsonAsciiSafeString]](unsafeAddr value[0])
  var idx = 0
  while idx < value.len:
    result = checkedJsonAdd(result, max(2, checkedJsonAdd(rawString(items[idx]).len, 2,
      "JSON string too large to serialize")))
    inc idx

proc writeValue[T: ref object](buf: var string, value: T) =
  if value == nil:
    buf.add("null")
  else:
    writeValue(buf, value[])

proc writeValue[T: object](buf: var string, value: T) =
  buf.add('{')
  writeObjectFields(buf, value)
  buf.add('}')

proc writeValue[T](buf: var string, value: Option[T]) =
  if value.isNone:
    buf.add("null")
  else:
    writeValue(buf, value.get)

proc writeValue[A, B](buf: var string, value: Table[A, B]) =
  buf.add('{')
  var first = true
  for k, v in value:
    if not first: buf.add(',')
    first = false
    when A is string:
      appendJsonEscaped(buf, k)
    elif A is enum:
      appendJsonEscaped(buf, $k)
    else:
      {.error: "Table key must be string or enum".}
    buf.add(':')
    writeValue(buf, v)
  buf.add('}')

proc writeValue[A, B](buf: var string, value: OrderedTable[A, B]) =
  buf.add('{')
  var first = true
  for k, v in value:
    if not first: buf.add(',')
    first = false
    when A is string:
      appendJsonEscaped(buf, k)
    elif A is enum:
      appendJsonEscaped(buf, $k)
    else:
      {.error: "OrderedTable key must be string or enum".}
    buf.add(':')
    writeValue(buf, v)
  buf.add('}')

proc estimateJsonSize(value: bool): int =
  if value: 4 else: 5

proc estimateJsonSize[T: SomeInteger](value: T): int =
  if value == 0: 1 else: 24

proc estimateJsonSize[T: SomeFloat](value: T): int =
  24

proc estimateJsonSize(value: string): int =
  max(2, checkedJsonAdd(value.len, 2, "JSON string too large to serialize"))

proc estimateJsonSize(value: JsonSafeString): int =
  max(2, checkedJsonAdd(rawString(value).len, 2, "JSON string too large to serialize"))

proc estimateJsonSize(value: JsonAsciiSafeString): int =
  max(2, checkedJsonAdd(rawString(value).len, 2, "JSON string too large to serialize"))

proc estimateJsonSize(value: BorrowedString): int =
  max(2, checkedJsonAdd(value.len, 2, "JSON string too large to serialize"))

proc estimateJsonSize[T: enum](value: T): int =
  estimateJsonSize($value)

proc estimateJsonSize[T](value: Option[T]): int =
  if value.isNone: 4 else: estimateJsonSize(value.get)

proc estimateJsonSize[A, B](value: Table[A, B]): int =
  if value.len == 0: return 2
  result = checkedJsonAdd(2, max(0, value.len - 1))  # {} + commas
  for k, v in value:
    when A is string:
      result = checkedJsonAdd(result, checkedJsonAdd(estimateJsonSize(k), checkedJsonAdd(1, estimateJsonSize(v))))
    else:
      result = checkedJsonAdd(result, checkedJsonAdd(11, estimateJsonSize(v)))  # rough key estimate

proc estimateJsonSize[A, B](value: OrderedTable[A, B]): int =
  if value.len == 0: return 2
  result = checkedJsonAdd(2, max(0, value.len - 1))
  for k, v in value:
    when A is string:
      result = checkedJsonAdd(result, checkedJsonAdd(estimateJsonSize(k), checkedJsonAdd(1, estimateJsonSize(v))))
    else:
      result = checkedJsonAdd(result, checkedJsonAdd(11, estimateJsonSize(v)))

proc estimateJsonSize[T](value: seq[T]): int =
  if value.len == 0:
    return 2
  if value.len <= 4:
    result = 2
    var idx = 0
    while idx < value.len:
      if idx > 0:
        result = checkedJsonAdd(result, 1)
      result = checkedJsonAdd(result, estimateJsonSize(value[idx]))
      inc idx
    return

  let firstSample = estimateJsonSize(value[0])
  let lastSample = estimateJsonSize(value[^1])
  let sample = max(8, checkedJsonAdd(firstSample, lastSample) shr 1)
  result = checkedJsonAdd(2, checkedJsonAdd(value.len - 1, checkedJsonMul(sample, value.len)))

proc estimateJsonSize[T: object](value: seq[T]): int =
  if value.len == 0:
    return 2
  # Use compile-time static overhead per element + sampling for dynamic fields.
  # Avoids O(n) traversal for large seqs.
  const staticPerItem = typeStaticJsonOverhead(default(T))
  if value.len <= 4:
    result = 2
    let items = cast[ptr UncheckedArray[T]](unsafeAddr value[0])
    var idx = 0
    while idx < value.len:
      if idx > 0:
        result = checkedJsonAdd(result, 1)
      result = checkedJsonAdd(result, estimateJsonSize(items[idx]))
      inc idx
    return
  # Sample first + last, multiply by count
  let firstDynamic = estimateJsonSize(value[0]) - staticPerItem
  let lastDynamic = estimateJsonSize(value[^1]) - staticPerItem
  let dynamicAvg = checkedJsonAdd(max(0, firstDynamic), max(0, lastDynamic)) shr 1
  let perItem = checkedJsonAdd(staticPerItem, dynamicAvg)
  result = checkedJsonAdd(2, checkedJsonAdd(value.len - 1,
    checkedJsonMul(max(16, perItem), value.len)))

proc estimateJsonSize[T: ref object](value: T): int =
  if value == nil: 4 else: estimateJsonSize(value[])

proc estimateJsonSize[T: object](value: T): int =
  result = typeStaticJsonOverhead(value)
  estimateDynamicFields(result, value)

proc initialCapacityForSerialize(estimated: int): int {.inline.} =
  ## Over-allocate generously so ensureRoom is never needed in the write path.
  ## Worst case JSON expansion (all escape chars) is ~6x, but realistic data
  ## is <1.1x. Keep the initial allocation at the actual worst-case envelope;
  ## field-level ensureRoom calls are a last defense against bad estimates.
  if estimated < 0 or estimated > (high(int) - 512) div 6:
    raise newException(JsonError, "JSON output too large to serialize")
  if estimated <= 128:
    return max(256, estimated * 6 + 64)
  if estimated <= 4096:
    return estimated * 6 + 128
  estimated * 6 + 256

proc cursorRoomForEstimate(estimated: int): int {.inline.} =
  ## Same slack envelope as initialCapacityForSerialize without the root-level
  ## minimum. Nested cursor writers use this before unchecked element writes.
  if estimated < 0 or estimated > (high(int) - 512) div 6:
    raise newException(JsonError, "JSON output too large to serialize")
  if estimated <= 128:
    return estimated * 6 + 64
  if estimated <= 4096:
    return estimated * 6 + 128
  estimated * 6 + 256

# === Cursor-based writeValueC functions ===
# These use pre-allocated buffer + pos cursor for zero-setLen serialization.

proc writeValueC[T](buf: var string, pos: var int, value: seq[T])
proc writeValueC(buf: var string, pos: var int, value: seq[string])
proc writeValueC(buf: var string, pos: var int, value: seq[JsonSafeString])
proc writeValueC(buf: var string, pos: var int, value: seq[JsonAsciiSafeString])
proc writeValueC[T: object](buf: var string, pos: var int, value: seq[T])
proc writeValueC[T: ref object](buf: var string, pos: var int, value: T)
proc writeValueC[T: object](buf: var string, pos: var int, value: T)
proc writeValueC(buf: var string, pos: var int, value: bool) {.inline.}
proc writeValueC[T: SomeInteger](buf: var string, pos: var int, value: T) {.inline.}
proc writeValueC[T: SomeFloat](buf: var string, pos: var int, value: T) {.inline.}
proc writeValueC(buf: var string, pos: var int, value: string)
proc writeValueC(buf: var string, pos: var int, value: JsonSafeString)
proc writeValueC(buf: var string, pos: var int, value: JsonAsciiSafeString)
proc writeValueC(buf: var string, pos: var int, value: BorrowedString)
proc writeValueC[T: enum](buf: var string, pos: var int, value: T)
proc writeValueC[T](buf: var string, pos: var int, value: Option[T])
proc writeValueC[A, B](buf: var string, pos: var int, value: Table[A, B])
proc writeValueC[A, B](buf: var string, pos: var int, value: OrderedTable[A, B])

macro writeObjectFieldsC(buf: typed, pos: typed, value: typed): untyped =
  ## Fused field name + value writes. For string fields, the opening quote
  ## is merged into the prefix literal (e.g., `,"name":"`) and cPutJsonBody
  ## writes the body + closing quote. This eliminates one byte write per
  ## string field by fusing it into the uint64 prefix store.
  result = newStmtList()
  var first = true
  let fields = objectFieldEntriesEx(value)
  for (fieldName, access, fieldKind) in fields:
    let prefix = if first: "\"" & fieldName & "\":" else: ",\"" & fieldName & "\":"
    first = false
    let prefixLit = newLit(prefix)
    let fusedLit = newLit(prefix & "\"")  # prefix + opening quote for strings
    if fieldKind in {jsfkJsonSafeString, jsfkAsciiSafeString}:
      # {.jsonSafe.} string — fused prefix + unescaped body
      result.add(newCall(bindSym"cPutLit", buf, pos, fusedLit))
      result.add(newCall(bindSym"cPutStrUnescapedBody", buf, pos,
        newCall(bindSym"rawString", access)))
    else:
      result.add(quote do:
        when typeof(`access`) is string:
          cPutLit(`buf`, `pos`, `fusedLit`)
          cPutJsonBody(`buf`, `pos`, `access`)
        elif typeof(`access`) is bool:
          cPutLit(`buf`, `pos`, `prefixLit`)
          writeValueC(`buf`, `pos`, `access`)
        elif typeof(`access`) is SomeInteger:
          cPutLit(`buf`, `pos`, `prefixLit`)
          cPutInt(`buf`, `pos`, `access`)
        elif typeof(`access`) is SomeFloat:
          cPutLit(`buf`, `pos`, `prefixLit`)
          cPutFloat(`buf`, `pos`, `access`)
        elif typeof(`access`) is seq[string]:
          cPutLit(`buf`, `pos`, `prefixLit`)
          `buf`[`pos`] = '['; inc `pos`
          var idx = 0
          while idx < `access`.len:
            if idx > 0:
              `buf`[`pos`] = ','; inc `pos`
            cPutJsonEscaped(`buf`, `pos`, `access`[idx])
            inc idx
          `buf`[`pos`] = ']'; inc `pos`
        elif typeof(`access`) is seq[SomeInteger]:
          cPutLit(`buf`, `pos`, `prefixLit`)
          ensureRoom(`buf`, `pos`, cursorRoomForEstimate(estimateJsonSize(`access`)))
          `buf`[`pos`] = '['; inc `pos`
          var idx = 0
          while idx < `access`.len:
            if idx > 0:
              `buf`[`pos`] = ','; inc `pos`
            cPutInt(`buf`, `pos`, `access`[idx])
            inc idx
          `buf`[`pos`] = ']'; inc `pos`
        else:
          cPutLit(`buf`, `pos`, `prefixLit`)
          writeValueC(`buf`, `pos`, `access`)
      )

proc cPutNull(buf: var string, pos: var int) {.inline.} =
  buf[pos] = 'n'; buf[pos+1] = 'u'; buf[pos+2] = 'l'; buf[pos+3] = 'l'
  pos += 4

proc writeValueC(buf: var string, pos: var int, value: bool) {.inline.} =
  if value:
    buf[pos] = 't'; buf[pos+1] = 'r'; buf[pos+2] = 'u'; buf[pos+3] = 'e'
    pos += 4
  else:
    buf[pos] = 'f'; buf[pos+1] = 'a'; buf[pos+2] = 'l'; buf[pos+3] = 's'; buf[pos+4] = 'e'
    pos += 5

proc writeValueC[T: SomeInteger](buf: var string, pos: var int, value: T) {.inline.} =
  cPutInt(buf, pos, value)

proc writeValueC[T: SomeFloat](buf: var string, pos: var int, value: T) {.inline.} =
  cPutFloat(buf, pos, float64(value))

proc writeValueC(buf: var string, pos: var int, value: string) =
  cPutJsonEscaped(buf, pos, value)

proc writeValueC(buf: var string, pos: var int, value: JsonSafeString) =
  cPutStrUnescaped(buf, pos, rawString(value))

proc writeValueC(buf: var string, pos: var int, value: JsonAsciiSafeString) =
  cPutStrUnescaped(buf, pos, rawString(value))

proc writeValueC(buf: var string, pos: var int, value: BorrowedString) =
  if value.isNil:
    buf[pos] = '"'; buf[pos + 1] = '"'
    pos += 2
  else:
    let vlen = value.len
    if vlen == 0:
      buf[pos] = '"'; buf[pos + 1] = '"'
      pos += 2
    else:
      var needsEscape = false
      let p = value.dataPtr
      for ci in 0 ..< vlen:
        let ch = p[ci]
        if ch == '"' or ch == '\\' or ord(ch) < 0x20:
          needsEscape = true
          break
      if not needsEscape:
        buf[pos] = '"'; inc pos
        copyMem(addr buf[pos], p, vlen)
        pos += vlen
        buf[pos] = '"'; inc pos
      else:
        cPutJsonEscaped(buf, pos, value.toString())

proc writeValueC[T: enum](buf: var string, pos: var int, value: T) =
  cPutJsonEscaped(buf, pos, $value)

proc writeValueC[T](buf: var string, pos: var int, value: Option[T]) =
  if value.isNone:
    cPutNull(buf, pos)
  else:
    writeValueC(buf, pos, value.get)

macro typeSafeStringOnlyFieldOverhead(value: typed): int =
  ## Compile-time constant for the fused field prefixes of an object whose
  ## fields are all serializer-safe strings (.jsonSafe. or safe wrappers).
  let info = objectTypeInfo(value)
  if SafeStringOnlyFieldOverheadCache.hasKey(info.key):
    return SafeStringOnlyFieldOverheadCache[info.key]
  var overhead = 0
  var first = true
  for field in info.impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[^2]
    for idx in 0 ..< field.len - 2:
      let kind = serializeFieldKindNode(fieldType, fieldNodeHasPragma(field[idx], "jsonSafe"))
      if kind notin {jsfkJsonSafeString, jsfkAsciiSafeString}:
        let lit = newLit(-1)
        SafeStringOnlyFieldOverheadCache[info.key] = lit
        return lit
      let fieldName = extractFieldName(field[idx])
      overhead += fieldName.len + 4
      if not first:
        inc overhead
      first = false
  let lit = newLit(overhead)
  SafeStringOnlyFieldOverheadCache[info.key] = lit
  return lit


proc writeValueC[A, B](buf: var string, pos: var int, value: Table[A, B]) =
  buf[pos] = '{'; inc pos
  var first = true
  for k, v in value:
    if not first:
      buf[pos] = ','; inc pos
    first = false
    when A is string:
      cPutJsonEscaped(buf, pos, k)
    elif A is enum:
      cPutJsonEscaped(buf, pos, $k)
    buf[pos] = ':'; inc pos
    writeValueC(buf, pos, v)
  buf[pos] = '}'; inc pos

proc writeValueC(buf: var string, pos: var int, value: Table[string, string]) =
  buf[pos] = '{'; inc pos
  var first = true
  for k, v in value:
    if not first:
      buf[pos] = ','; inc pos
    first = false
    cPutJsonEscaped(buf, pos, k)
    buf[pos] = ':'; inc pos
    cPutJsonEscaped(buf, pos, v)
  buf[pos] = '}'; inc pos

proc writeValueC(buf: var string, pos: var int, value: Table[string, JsonSafeString]) =
  buf[pos] = '{'; inc pos
  var first = true
  for k, v in value:
    if not first:
      buf[pos] = ','; inc pos
    first = false
    cPutJsonEscaped(buf, pos, k)
    buf[pos] = ':'; inc pos
    cPutStrUnescaped(buf, pos, rawString(v))
  buf[pos] = '}'; inc pos

proc writeValueC(buf: var string, pos: var int, value: Table[string, JsonAsciiSafeString]) =
  buf[pos] = '{'; inc pos
  var first = true
  for k, v in value:
    if not first:
      buf[pos] = ','; inc pos
    first = false
    cPutJsonEscaped(buf, pos, k)
    buf[pos] = ':'; inc pos
    cPutStrUnescaped(buf, pos, rawString(v))
  buf[pos] = '}'; inc pos

proc writeValueC(buf: var string, pos: var int, value: Table[string, seq[int]]) =
  buf[pos] = '{'; inc pos
  var first = true
  for k, v in value:
    if not first:
      buf[pos] = ','; inc pos
    first = false
    cPutJsonEscaped(buf, pos, k)
    buf[pos] = ':'; inc pos
    ensureRoom(buf, pos, cursorRoomForEstimate(estimateJsonSize(v)))
    buf[pos] = '['; inc pos
    var idx = 0
    while idx < v.len:
      if idx > 0:
        buf[pos] = ','; inc pos
      cPutInt(buf, pos, v[idx])
      inc idx
    buf[pos] = ']'; inc pos
  buf[pos] = '}'; inc pos

proc writeValueC[T: object](buf: var string, pos: var int, value: Table[string, T]) =
  ## Specialized object-valued table path for CITM-like maps.
  buf[pos] = '{'; inc pos
  var first = true
  let valueRef = cast[ptr Table[string, T]](unsafeAddr value)
  for k, v in mpairs(valueRef[]):
    if not first:
      buf[pos] = ','; inc pos
    first = false
    cPutJsonEscaped(buf, pos, k)
    buf[pos] = ':'; inc pos
    buf[pos] = '{'; inc pos
    writeObjectFieldsC(buf, pos, v)
    buf[pos] = '}'; inc pos
  buf[pos] = '}'; inc pos

proc writeValueC[T: object](buf: var string, pos: var int, value: OrderedTable[string, T]) =
  buf[pos] = '{'; inc pos
  var first = true
  let valueRef = cast[ptr OrderedTable[string, T]](unsafeAddr value)
  for k, v in mpairs(valueRef[]):
    if not first:
      buf[pos] = ','; inc pos
    first = false
    cPutJsonEscaped(buf, pos, k)
    buf[pos] = ':'; inc pos
    buf[pos] = '{'; inc pos
    writeObjectFieldsC(buf, pos, v)
    buf[pos] = '}'; inc pos
  buf[pos] = '}'; inc pos

proc writeValueC(buf: var string, pos: var int, value: OrderedTable[string, JsonSafeString]) =
  buf[pos] = '{'; inc pos
  var first = true
  for k, v in value:
    if not first:
      buf[pos] = ','; inc pos
    first = false
    cPutJsonEscaped(buf, pos, k)
    buf[pos] = ':'; inc pos
    cPutStrUnescaped(buf, pos, rawString(v))
  buf[pos] = '}'; inc pos

proc writeValueC(buf: var string, pos: var int, value: OrderedTable[string, JsonAsciiSafeString]) =
  buf[pos] = '{'; inc pos
  var first = true
  for k, v in value:
    if not first:
      buf[pos] = ','; inc pos
    first = false
    cPutJsonEscaped(buf, pos, k)
    buf[pos] = ':'; inc pos
    cPutStrUnescaped(buf, pos, rawString(v))
  buf[pos] = '}'; inc pos

proc writeValueC[A, B](buf: var string, pos: var int, value: OrderedTable[A, B]) =
  buf[pos] = '{'; inc pos
  var first = true
  for k, v in value:
    if not first:
      buf[pos] = ','; inc pos
    first = false
    when A is string:
      cPutJsonEscaped(buf, pos, k)
    elif A is enum:
      cPutJsonEscaped(buf, pos, $k)
    buf[pos] = ':'; inc pos
    writeValueC(buf, pos, v)
  buf[pos] = '}'; inc pos

proc writeValueC[T](buf: var string, pos: var int, value: seq[T]) =
  ensureRoom(buf, pos, cursorRoomForEstimate(estimateJsonSize(value)))
  buf[pos] = '['; inc pos
  var idx = 0
  while idx < value.len:
    if idx > 0:
      buf[pos] = ','; inc pos
    writeValueC(buf, pos, value[idx])
    inc idx
  buf[pos] = ']'; inc pos

proc writeValueC(buf: var string, pos: var int, value: seq[string]) =
  ensureRoom(buf, pos, cursorRoomForEstimate(estimateJsonSize(value)))
  buf[pos] = '['; inc pos
  if value.len > 0:
    let items = cast[ptr UncheckedArray[string]](unsafeAddr value[0])
    var idx = 0
    while idx < value.len:
      if idx > 0:
        buf[pos] = ','; inc pos
      cPutJsonEscaped(buf, pos, items[idx])
      inc idx
  buf[pos] = ']'; inc pos

proc writeValueC(buf: var string, pos: var int, value: seq[float64]) =
  ## Bounded Canada-style point fast path: [x, y, 0.0] is common in the real dataset.
  ## Avoid one dragonbox call per point when the trailing altitude is the literal zero.
  ensureRoom(buf, pos, cursorRoomForEstimate(estimateJsonSize(value)))
  if value.len == 3 and value[2] == 0.0:
    buf[pos] = '['; inc pos
    cPutFloat(buf, pos, value[0])
    buf[pos] = ','; inc pos
    cPutFloat(buf, pos, value[1])
    cPutLit(buf, pos, ",0.0]")
    return

  buf[pos] = '['; inc pos
  var idx = 0
  while idx < value.len:
    if idx > 0:
      buf[pos] = ','; inc pos
    cPutFloat(buf, pos, value[idx])
    inc idx
  buf[pos] = ']'; inc pos

# === Batch float formatting for seq[object] ===
# Pre-format all float fields in a tight loop for better icache utilization,
# then pull from the pre-formatted buffer during structural serialization.

type FloatBatch = object
  data: ptr UncheckedArray[char]
  offsets: ptr UncheckedArray[int32]  # start offset of each formatted float
  lens: ptr UncheckedArray[int16]     # length of each formatted float
  count: int
  buf: string       # owns the data memory
  offsetBuf: string  # owns the offsets memory
  lenBuf: string     # owns the lens memory

type StringScanBatch* = object
  lengths*: ptr UncheckedArray[int32]
  firstUnsafe*: ptr UncheckedArray[int32]
  count*: int
  lengthBuf: string
  firstUnsafeBuf: string

## Allocates a StringScanBatch with length and firstUnsafe buffers for the given string count.
proc initStringScanBatch*(totalStrings: int): StringScanBatch =
  result.count = totalStrings
  if totalStrings <= 0:
    return
  let bytes = checkedJsonMul(totalStrings, sizeof(int32), "too many strings to stage")
  result.lengthBuf = newString(bytes)
  result.lengths = cast[ptr UncheckedArray[int32]](addr result.lengthBuf[0])
  result.firstUnsafeBuf = newString(bytes)
  result.firstUnsafe = cast[ptr UncheckedArray[int32]](addr result.firstUnsafeBuf[0])

type EscapedBodyBatch* = object
  data*: ptr UncheckedArray[char]
  offsets*: ptr UncheckedArray[int32]
  lens*: ptr UncheckedArray[int32]
  count*: int
  dataBuf: string
  offsetBuf: string
  lenBuf: string

## Allocates an EscapedBodyBatch with data, offset and length buffers for staging string bodies.
proc initEscapedBodyBatch*(totalStrings: int, totalBytes: int): EscapedBodyBatch =
  result.count = totalStrings
  if totalStrings <= 0:
    return
  if totalBytes < 0:
    raise newException(JsonError, "JSON string batch too large to serialize")
  result.dataBuf = newString(max(1, totalBytes))
  result.data = cast[ptr UncheckedArray[char]](addr result.dataBuf[0])
  let indexBytes = checkedJsonMul(totalStrings, sizeof(int32), "too many strings to stage")
  result.offsetBuf = newString(indexBytes)
  result.offsets = cast[ptr UncheckedArray[int32]](addr result.offsetBuf[0])
  result.lenBuf = newString(indexBytes)
  result.lens = cast[ptr UncheckedArray[int32]](addr result.lenBuf[0])

proc initFloatBatch(totalFloats: int): FloatBatch =
  result.count = 0
  if totalFloats <= 0:
    return
  result.buf = newString(checkedJsonMul(totalFloats, 24, "too many floats to serialize"))
  result.data = cast[ptr UncheckedArray[char]](addr result.buf[0])
  result.offsetBuf = newString(checkedJsonMul(totalFloats, sizeof(int32), "too many floats to serialize"))
  result.offsets = cast[ptr UncheckedArray[int32]](addr result.offsetBuf[0])
  result.lenBuf = newString(checkedJsonMul(totalFloats, sizeof(int16), "too many floats to serialize"))
  result.lens = cast[ptr UncheckedArray[int16]](addr result.lenBuf[0])

type IntBatch = object
  data: ptr UncheckedArray[char]
  offsets: ptr UncheckedArray[int32]  # start offset of each formatted int
  lens: ptr UncheckedArray[int8]     # length of each formatted int (max 20 digits)
  count: int
  buf: string       # owns the data memory
  offsetBuf: string  # owns the offsets memory
  lenBuf: string     # owns the lens memory

const IntBatchBytesPerInt = 21

proc initIntBatch(totalInts: int): IntBatch =
  result.count = 0
  if totalInts <= 0:
    return
  if totalInts > high(int) div IntBatchBytesPerInt:
    raise newException(JsonError, "too many integers to serialize")
  result.buf = newString(totalInts * IntBatchBytesPerInt)
  result.data = cast[ptr UncheckedArray[char]](addr result.buf[0])
  result.offsetBuf = newString(checkedJsonMul(totalInts, sizeof(int32), "too many integers to serialize"))
  result.offsets = cast[ptr UncheckedArray[int32]](addr result.offsetBuf[0])
  result.lenBuf = newString(checkedJsonMul(totalInts, sizeof(int8), "too many integers to serialize"))
  result.lens = cast[ptr UncheckedArray[int8]](addr result.lenBuf[0])

proc resolveObjectImpl(node: NimNode): NimNode =
  ## Resolve the object type impl from any typed node, unwrapping
  ## ptr UncheckedArray[T], seq[T], ref T, etc.
  var valueType = node.getTypeInst
  # Unwrap ptr UncheckedArray[T]
  if valueType.kind == nnkPtrTy:
    valueType = valueType[0]
  if valueType.kind == nnkBracketExpr:
    if eqIdent(valueType[0], "UncheckedArray") or eqIdent(valueType[0], "seq"):
      valueType = valueType[1]
  if valueType.kind == nnkRefTy:
    valueType = valueType[0]
  var impl = getTypeImpl(valueType)
  if impl.kind == nnkSym:
    impl = getTypeImpl(impl)
  if impl.kind == nnkRefTy:
    impl = getTypeImpl(impl[0])
  if impl.kind != nnkObjectTy:
    error("resolveObjectImpl expects an object type, got: " & impl.repr, node)
  impl

macro countFloatFieldsInType(value: typed): int =
  ## Count float fields in an object type at compile time.
  let impl = resolveObjectImpl(value)
  let key = impl.repr
  if FloatFieldCountCache.hasKey(key):
    return FloatFieldCountCache[key]
  var count = 0
  for field in impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[^2]
    if fieldType.kind == nnkSym and (eqIdent(fieldType, "float64") or
        eqIdent(fieldType, "float32") or eqIdent(fieldType, "float")):
      for idx in 0 ..< field.len - 2:
        inc count
  let lit = newLit(count)
  FloatFieldCountCache[key] = lit
  return lit

macro countIntFieldsInType(value: typed): int =
  ## Count integer fields in an object type at compile time.
  let impl = resolveObjectImpl(value)
  let key = impl.repr
  if IntFieldCountCache.hasKey(key):
    return IntFieldCountCache[key]
  var count = 0
  for field in impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[^2]
    if fieldType.kind == nnkSym and (eqIdent(fieldType, "int") or
        eqIdent(fieldType, "int64") or eqIdent(fieldType, "int32") or
        eqIdent(fieldType, "int16") or eqIdent(fieldType, "int8") or
        eqIdent(fieldType, "uint") or eqIdent(fieldType, "uint64") or
        eqIdent(fieldType, "uint32") or eqIdent(fieldType, "uint16") or
        eqIdent(fieldType, "uint8")):
      for idx in 0 ..< field.len - 2:
        inc count
  let lit = newLit(count)
  IntFieldCountCache[key] = lit
  return lit

macro countStringFieldsInType(value: typed): int =
  ## Count string fields in an object type at compile time.
  let impl = resolveObjectImpl(value)
  let key = impl.repr
  if StringFieldCountCache.hasKey(key):
    return StringFieldCountCache[key]
  var count = 0
  for field in impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[^2]
    if fieldType.kind == nnkSym and eqIdent(fieldType, "string"):
      for idx in 0 ..< field.len - 2:
        inc count
  let lit = newLit(count)
  StringFieldCountCache[key] = lit
  return lit

## Compile-time count of string fields in an object type T.
template stringFieldCount*[T](_: typedesc[T]): int =
  countStringFieldsInType(default(T))

macro typeStringOnlyFieldOverhead(value: typed): int =
  ## Compile-time constant for the fused field prefixes of a string-only object.
  ## Excludes object braces and the staged string bodies themselves.
  let info = objectTypeInfo(value)
  if StringOnlyFieldOverheadCache.hasKey(info.key):
    return StringOnlyFieldOverheadCache[info.key]
  var overhead = 0
  var first = true
  for field in info.impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[^2]
    if fieldType.kind != nnkSym or not eqIdent(fieldType, "string"):
      let lit = newLit(-1)
      StringOnlyFieldOverheadCache[info.key] = lit
      return lit
    for idx in 0 ..< field.len - 2:
      let fieldName = extractFieldName(field[idx])
      overhead += fieldName.len + 4 # "name":" fused prefix
      if not first:
        inc overhead # leading comma for non-first fields
      first = false
  let lit = newLit(overhead)
  StringOnlyFieldOverheadCache[info.key] = lit
  return lit


macro preformatFloats(items: typed, count: typed, floatBuf: typed,
                       floatOff: typed, floatLen: typed, floatIdx: typed): untyped =
  ## Generate a tight loop that extracts and formats all float fields from items[0..count-1].
  let impl = resolveObjectImpl(items)
  var floatFields: seq[string]
  for field in impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[^2]
    if fieldType.kind == nnkSym and (eqIdent(fieldType, "float64") or
        eqIdent(fieldType, "float32") or eqIdent(fieldType, "float")):
      for idx in 0 ..< field.len - 2:
        floatFields.add(extractFieldName(field[idx]))

  if floatFields.len == 0:
    return newStmtList()

  result = newStmtList()
  let offSym = genSym(nskVar, "off")
  let fiSym = genSym(nskVar, "fi")
  let iSym = genSym(nskForVar, "i")
  result.add(newVarStmt(offSym, newLit(0)))
  result.add(newVarStmt(fiSym, newLit(0)))

  # Tight loop: for i in 0..<count: for each float field: format
  var loopBody = newStmtList()
  for fname in floatFields:
    let access = nnkDotExpr.newTree(nnkBracketExpr.newTree(items, iSym), ident(fname))
    loopBody.add(quote do:
      block:
        var fbuf {.noinit.}: array[65, char]
        let n = toChars(fbuf, float64(`access`), forceTrailingDotZero = true).int
        copyMem(addr `floatBuf`[`offSym`], addr fbuf[0], n)
        `floatOff`[`fiSym`] = int32(`offSym`)
        `floatLen`[`fiSym`] = int16(n)
        `offSym` += n
        inc `fiSym`
    )

  result.add(newNimNode(nnkForStmt).add(
    iSym,
    infix(newLit(0), "..<", count),
    loopBody
  ))
  result.add(newAssignment(floatIdx, newLit(0)))

macro preformatInts(items: typed, count: typed, intBuf: typed,
                     intOff: typed, intLen: typed, intIdx: typed): untyped =
  ## Generate a tight loop that formats all integer fields from items[0..count-1].
  let impl = resolveObjectImpl(items)
  var intFields: seq[string]
  for field in impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[^2]
    if fieldType.kind == nnkSym and (eqIdent(fieldType, "int") or
        eqIdent(fieldType, "int64") or eqIdent(fieldType, "int32") or
        eqIdent(fieldType, "int16") or eqIdent(fieldType, "int8") or
        eqIdent(fieldType, "uint") or eqIdent(fieldType, "uint64") or
        eqIdent(fieldType, "uint32") or eqIdent(fieldType, "uint16") or
        eqIdent(fieldType, "uint8")):
      for idx in 0 ..< field.len - 2:
        intFields.add(extractFieldName(field[idx]))

  if intFields.len == 0:
    return newStmtList()

  # We reuse the same DigitPairs LUT and algorithm as cPutInt,
  # but write directly into the batch buffer.
  result = newStmtList()
  let offSym = genSym(nskVar, "ioff")
  let iiSym = genSym(nskVar, "ii")
  let iSym = genSym(nskForVar, "i")
  result.add(newVarStmt(offSym, newLit(0)))
  result.add(newVarStmt(iiSym, newLit(0)))

  var loopBody = newStmtList()
  for fname in intFields:
    let access = nnkDotExpr.newTree(nnkBracketExpr.newTree(items, iSym), ident(fname))
    loopBody.add(quote do:
      block:
        var digits {.noinit.}: array[32, char]
        var dpos = 32
        var raw = uint64(`access`)
        when typeof(`access`) is SomeSignedInt:
          if int64(`access`) < 0:
            # Negative: use string fallback into batch buf
            let s = $(`access`)
            copyMem(addr `intBuf`[`offSym`], unsafeAddr s[0], s.len)
            `intOff`[`iiSym`] = int32(`offSym`)
            `intLen`[`iiSym`] = int8(s.len)
            `offSym` += s.len
            inc `iiSym`
          else:
            if raw == 0'u64:
              dec dpos
              digits[dpos] = '0'
            else:
              var current = raw
              while current >= 100'u64:
                let pair = int(current mod 100)
                current = current div 100
                dpos -= 2
                digits[dpos] = DigitPairs[pair][0]
                digits[dpos + 1] = DigitPairs[pair][1]
              if current < 10'u64:
                dec dpos
                digits[dpos] = char(ord('0') + int(current))
              else:
                dpos -= 2
                digits[dpos] = DigitPairs[int(current)][0]
                digits[dpos + 1] = DigitPairs[int(current)][1]
            let copyLen = 32 - dpos
            copyMem(addr `intBuf`[`offSym`], addr digits[dpos], copyLen)
            `intOff`[`iiSym`] = int32(`offSym`)
            `intLen`[`iiSym`] = int8(copyLen)
            `offSym` += copyLen
            inc `iiSym`
        else:
          if raw == 0'u64:
            dec dpos
            digits[dpos] = '0'
          else:
            var current = raw
            while current >= 100'u64:
              let pair = int(current mod 100)
              current = current div 100
              dpos -= 2
              digits[dpos] = DigitPairs[pair][0]
              digits[dpos + 1] = DigitPairs[pair][1]
            if current < 10'u64:
              dec dpos
              digits[dpos] = char(ord('0') + int(current))
            else:
              dpos -= 2
              digits[dpos] = DigitPairs[int(current)][0]
              digits[dpos + 1] = DigitPairs[int(current)][1]
          let copyLen = 32 - dpos
          copyMem(addr `intBuf`[`offSym`], addr digits[dpos], copyLen)
          `intOff`[`iiSym`] = int32(`offSym`)
          `intLen`[`iiSym`] = int8(copyLen)
          `offSym` += copyLen
          inc `iiSym`
    )

  result.add(newNimNode(nnkForStmt).add(
    iSym,
    infix(newLit(0), "..<", count),
    loopBody
  ))
  result.add(newAssignment(intIdx, newLit(0)))

macro preScanStrings(items: typed, count: typed, lengths: typed,
    firstUnsafe: typed, stringIdx: typed): untyped =
  ## Generate a tight loop that captures string lengths and the first unsafe
  ## byte position for every string field in items[0..count-1].
  let impl = resolveObjectImpl(items)
  var stringFields: seq[string]
  for field in impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[^2]
    if fieldType.kind == nnkSym and eqIdent(fieldType, "string"):
      for idx in 0 ..< field.len - 2:
        stringFields.add(extractFieldName(field[idx]))

  if stringFields.len == 0:
    return newStmtList()

  result = newStmtList()
  let siSym = genSym(nskVar, "si")
  let iSym = genSym(nskForVar, "i")
  result.add(newVarStmt(siSym, newLit(0)))

  var loopBody = newStmtList()
  for fname in stringFields:
    let access = nnkDotExpr.newTree(nnkBracketExpr.newTree(items, iSym), ident(fname))
    loopBody.add(quote do:
      block:
        `lengths`[`siSym`] = checkedJsonInt32(`access`.len)
        if `access`.len == 0:
          `firstUnsafe`[`siSym`] = 0'i32
        else:
          `firstUnsafe`[`siSym`] = checkedJsonInt32(nextUnsafeJsonByte(`access`, 0))
        inc `siSym`
    )

  result.add(newNimNode(nnkForStmt).add(
    iSym,
    infix(newLit(0), "..<", count),
    loopBody
  ))
  result.add(newAssignment(stringIdx, newLit(0)))

## Computes the escaped body length of a string using known firstUnsafe metadata.
proc stagedBodyLenForString*(value: string, firstUnsafe: int): int {.inline.} =
  ## Exact body bytes plus closing quote using known firstUnsafe metadata.
  let vlen = value.len
  if vlen == 0:
    return 1
  if firstUnsafe >= vlen:
    return checkedJsonAdd(vlen, 1, "JSON string too large to stage")
  result = firstUnsafe
  var i = firstUnsafe
  while i < vlen:
    let unsafeAt = nextUnsafeJsonByte(value, i)
    result = checkedJsonAdd(result, unsafeAt - i, "JSON string too large to stage")
    if unsafeAt >= vlen:
      break
    result = checkedJsonAdd(result, int(EscapeSeq.lens[ord(value[unsafeAt])]), "JSON string too large to stage")
    i = unsafeAt + 1
  result = checkedJsonAdd(result, 1, "JSON string too large to stage")

## Stages the escaped body and closing quote of a string into a destination buffer at start.
proc stageJsonBodyKnown*(dst: ptr UncheckedArray[char], start: int, value: string,
                         firstUnsafe: int): int =
  ## Stage body + closing quote into ``dst`` starting at ``start`` using known firstUnsafe.
  ## Returns bytes written. No opening quote is emitted.
  let vlen = value.len
  var pos = start
  if vlen == 0:
    dst[pos] = '"'
    return 1
  if firstUnsafe >= vlen:
    copyMem(addr dst[pos], unsafeAddr value[0], vlen)
    pos += vlen
    dst[pos] = '"'
    return vlen + 1

  if firstUnsafe > 0:
    copyMem(addr dst[pos], unsafeAddr value[0], firstUnsafe)
    pos += firstUnsafe

  var i = firstUnsafe
  let b0 = ord(value[i])
  let escLen0 = int(EscapeSeq.lens[b0])
  var esc0 = EscapeSeq.seqs[b0]
  copyMem(addr dst[pos], addr esc0[0], escLen0)
  pos += escLen0
  i += 1

  while i < vlen:
    let unsafeAt = nextUnsafeJsonByte(value, i)
    let safeLen = unsafeAt - i
    if safeLen > 0:
      copyMem(addr dst[pos], unsafeAddr value[i], safeLen)
      pos += safeLen
    if unsafeAt >= vlen:
      break
    let b = ord(value[unsafeAt])
    let escLen = int(EscapeSeq.lens[b])
    var esc = EscapeSeq.seqs[b]
    copyMem(addr dst[pos], addr esc[0], escLen)
    pos += escLen
    i = unsafeAt + 1

  dst[pos] = '"'
  pos - start + 1

macro stageScannedStringBodies(items: typed, count: typed, lengths: typed,
    firstUnsafe: typed, data: typed, offsets: typed, lens: typed, stringIdx: typed): untyped =
  ## Generate a tight loop that stages each string field body+closing quote
  ## into reusable batch storage, in row order.
  let impl = resolveObjectImpl(items)
  var stringFields: seq[string]
  for field in impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[^2]
    if fieldType.kind == nnkSym and eqIdent(fieldType, "string"):
      for idx in 0 ..< field.len - 2:
        stringFields.add(extractFieldName(field[idx]))

  if stringFields.len == 0:
    return newStmtList()

  result = newStmtList()
  let siSym = genSym(nskVar, "stageIdx")
  let offSym = genSym(nskVar, "stageOff")
  let iSym = genSym(nskForVar, "i")
  result.add(newVarStmt(siSym, newLit(0)))
  result.add(newVarStmt(offSym, newLit(0)))

  var loopBody = newStmtList()
  for fname in stringFields:
    let access = nnkDotExpr.newTree(nnkBracketExpr.newTree(items, iSym), ident(fname))
    loopBody.add(quote do:
      block:
        `offsets`[`siSym`] = int32(`offSym`)
        let written = stageJsonBodyKnown(`data`, `offSym`, `access`, int(`firstUnsafe`[`siSym`]))
        `lens`[`siSym`] = int32(written)
        `offSym` += written
        inc `siSym`
    )

  result.add(newNimNode(nnkForStmt).add(
    iSym,
    infix(newLit(0), "..<", count),
    loopBody
  ))
  result.add(newAssignment(stringIdx, newLit(0)))

macro writeStringOnlyObjectFieldsFromBatch(buf: typed, pos: typed, value: typed,
    data: typed, offsets: typed, lens: typed, stringIdx: typed): untyped =
  ## Write a string-only object's field prefixes plus staged bodies in row order.
  result = newStmtList()
  var first = true
  let fields = objectFieldEntriesEx(value)
  for (fieldName, _, _) in fields:
    let fusedPrefix = if first:
        "\"" & fieldName & "\":\""
      else:
        ",\"" & fieldName & "\":\""
    first = false
    let fusedLit = newLit(fusedPrefix)
    result.add(newCall(bindSym"cPutLit", buf, pos, fusedLit))
    result.add(quote do:
      block:
        let si = `stringIdx`
        let slen = int(`lens`[si])
        let soff = int(`offsets`[si])
        copyMem(addr `buf`[`pos`], addr `data`[soff], slen)
        `pos` += slen
        inc `stringIdx`
    )

macro writeSafeStringOnlyObjectFieldsC(buf: typed, pos: typed, value: typed): untyped =
  ## Write an object whose fields are all serializer-safe strings.
  ## Uses fused prefixes and direct unescaped body copies in row order.
  result = newStmtList()
  var first = true
  let fields = objectFieldEntriesEx(value)
  for (fieldName, access, fieldKind) in fields:
    if fieldKind notin {jsfkJsonSafeString, jsfkAsciiSafeString}:
      error("writeSafeStringOnlyObjectFieldsC requires only safe-string fields", value)
    let fusedPrefix = if first:
        "\"" & fieldName & "\":\""
      else:
        ",\"" & fieldName & "\":\""
    first = false
    let fusedLit = newLit(fusedPrefix)
    result.add(newCall(bindSym"cPutLit", buf, pos, fusedLit))
    result.add(newCall(bindSym"cPutStrUnescapedBody", buf, pos,
      newCall(bindSym"unescapedBodyString", access)))

macro sumStagedStringBytes(items: typed, count: typed, totalBytes: typed): untyped =
  ## Generate a tight loop that sums exact staged body lengths for all string
  ## fields in row order.
  let impl = resolveObjectImpl(items)
  var stringFields: seq[string]
  for field in impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[^2]
    if fieldType.kind == nnkSym and eqIdent(fieldType, "string"):
      for idx in 0 ..< field.len - 2:
        stringFields.add(extractFieldName(field[idx]))

  if stringFields.len == 0:
    return newStmtList()

  result = newStmtList()
  let iSym = genSym(nskForVar, "i")
  var loopBody = newStmtList()
  for fname in stringFields:
    let access = nnkDotExpr.newTree(nnkBracketExpr.newTree(items, iSym), ident(fname))
    loopBody.add(quote do:
      `totalBytes` += stagedBodyLenForString(`access`, nextUnsafeJsonByte(`access`, 0))
    )
  result.add(newNimNode(nnkForStmt).add(
    iSym,
    infix(newLit(0), "..<", count),
    loopBody
  ))

## Debug helper returning length and firstUnsafe index pairs for every string field.
proc debugCollectStringScanBatch*[T: object](value: seq[T]): seq[(int, int)] =
  ## Debug/testing helper for GEN-004 groundwork.
  ## Returns one entry per string field in row order:
  ## (string length, first unsafe index or value.len if fully safe).
  if value.len == 0:
    return @[]
  let items = cast[ptr UncheckedArray[T]](unsafeAddr value[0])
  let totalStrings = checkedJsonMul(countStringFieldsInType(items[0]), value.len, "too many strings to stage")
  var batch = initStringScanBatch(totalStrings)
  var stringIdx = 0
  preScanStrings(items, value.len, batch.lengths, batch.firstUnsafe, stringIdx)
  result = newSeq[(int, int)](totalStrings)
  var idx = 0
  while idx < totalStrings:
    result[idx] = (int(batch.lengths[idx]), int(batch.firstUnsafe[idx]))
    inc idx

## Debug helper returning staged string bodies in row order, each with the closing quote.
proc debugStageStringBodies*[T: object](value: seq[T]): seq[string] =
  ## Debug/testing helper for GEN-016 groundwork.
  ## Returns staged string bodies in row order, each including the closing quote
  ## but not the opening quote. Safe string `abc` becomes `abc"`.
  if value.len == 0:
    return @[]
  let items = cast[ptr UncheckedArray[T]](unsafeAddr value[0])
  let totalStrings = checkedJsonMul(countStringFieldsInType(items[0]), value.len, "too many strings to stage")
  var scan = initStringScanBatch(totalStrings)
  var stringIdx = 0
  preScanStrings(items, value.len, scan.lengths, scan.firstUnsafe, stringIdx)
  var totalBytes = 0
  sumStagedStringBytes(items, value.len, totalBytes)

  var staged = initEscapedBodyBatch(totalStrings, totalBytes)
  stringIdx = 0
  stageScannedStringBodies(items, value.len, scan.lengths, scan.firstUnsafe,
    staged.data, staged.offsets, staged.lens, stringIdx)
  result = newSeq[string](totalStrings)
  var idx = 0
  while idx < totalStrings:
    let off = int(staged.offsets[idx])
    let slen = int(staged.lens[idx])
    result[idx] = newString(slen)
    copyMem(addr result[idx][0], addr staged.data[off], slen)
    inc idx

proc writeStringOnlySeqObjectsDirect[T: object](buf: var string, pos: var int, value: seq[T]) =
  ## Direct-position writer for seq[object] roots whose fields are all strings.
  ## Uses staged string bodies so final emission never rereads source bytes.
  buf[pos] = '['
  inc pos
  if value.len == 0:
    buf[pos] = ']'
    inc pos
    return

  let items = cast[ptr UncheckedArray[T]](unsafeAddr value[0])
  const stringsPerItem = countStringFieldsInType(items[0])
  const fieldOverhead = typeStringOnlyFieldOverhead(items[0])
  let totalStrings = checkedJsonMul(stringsPerItem, value.len, "too many strings to stage")

  var scan = initStringScanBatch(totalStrings)
  var stringIdx = 0
  preScanStrings(items, value.len, scan.lengths, scan.firstUnsafe, stringIdx)
  var worstCaseBytes = 0
  var idx = 0
  while idx < totalStrings:
    worstCaseBytes = checkedJsonAdd(worstCaseBytes,
      worstJsonStringBytes(int(scan.lengths[idx]), 1), "JSON string batch too large to serialize")
    inc idx

  var staged = initEscapedBodyBatch(totalStrings, worstCaseBytes)
  stringIdx = 0
  stageScannedStringBodies(items, value.len, scan.lengths, scan.firstUnsafe,
    staged.data, staged.offsets, staged.lens, stringIdx)

  var stagedBytes = 0
  idx = 0
  while idx < totalStrings:
    stagedBytes = checkedJsonAdd(stagedBytes, int(staged.lens[idx]),
      "JSON string batch too large to serialize")
    inc idx

  let exactBytes = checkedJsonAdd(
    checkedJsonAdd(2, max(0, value.len - 1)),
    checkedJsonAdd(checkedJsonMul(value.len, checkedJsonAdd(2, fieldOverhead)),
      stagedBytes)
  )
  let required = checkedJsonAdd(pos - 1, exactBytes)
  if required > buf.len:
    buf.setLen(required)

  stringIdx = 0
  idx = 0
  while idx < value.len:
    if idx > 0:
      buf[pos] = ','
      inc pos
    buf[pos] = '{'
    inc pos
    writeStringOnlyObjectFieldsFromBatch(buf, pos, items[idx],
      staged.data, staged.offsets, staged.lens, stringIdx)
    buf[pos] = '}'
    inc pos
    inc idx
  buf[pos] = ']'
  inc pos

proc writeSafeStringOnlySeqObjectsC[T: object](buf: var string, pos: var int, value: seq[T]) =
  ## One-pass row-order writer for seq[object] roots whose fields are all
  ## serializer-safe strings. No escape scanning, no staging.
  buf[pos] = '['
  inc pos
  if value.len == 0:
    buf[pos] = ']'
    inc pos
    return

  let items = cast[ptr UncheckedArray[T]](unsafeAddr value[0])
  var idx = 0
  while idx < value.len:
    if idx > 0:
      buf[pos] = ','
      inc pos
    buf[pos] = '{'
    inc pos
    writeSafeStringOnlyObjectFieldsC(buf, pos, items[idx])
    buf[pos] = '}'
    inc pos
    inc idx
  buf[pos] = ']'
  inc pos

proc writeSafeStringOnlyTableObjectsC[T: object](
  buf: var string,
  pos: var int,
  value: Table[string, T]
) =
  ## Root writer for string-keyed object maps whose object fields are all
  ## serializer-safe strings. Keys remain generic JSON strings.
  buf[pos] = '{'
  inc pos
  var first = true
  for key, entry in value.pairs:
    if not first:
      buf[pos] = ','
      inc pos
    first = false
    cPutJsonEscaped(buf, pos, key)
    buf[pos] = ':'
    inc pos
    buf[pos] = '{'
    inc pos
    writeSafeStringOnlyObjectFieldsC(buf, pos, entry)
    buf[pos] = '}'
    inc pos
  buf[pos] = '}'
  inc pos

proc writeSafeStringOnlyTableObjectsC[T: object](
  buf: var string,
  pos: var int,
  value: OrderedTable[string, T]
) =
  ## OrderedTable variant of the safe-string-only object-map root writer.
  buf[pos] = '{'
  inc pos
  var first = true
  for key, entry in value.pairs:
    if not first:
      buf[pos] = ','
      inc pos
    first = false
    cPutJsonEscaped(buf, pos, key)
    buf[pos] = ':'
    inc pos
    buf[pos] = '{'
    inc pos
    writeSafeStringOnlyObjectFieldsC(buf, pos, entry)
    buf[pos] = '}'
    inc pos
  buf[pos] = '}'
  inc pos

## Debug helper serializing a string-only object seq via the direct-position writer.
proc debugSerializeStringOnlySeqDirect*[T: object](value: seq[T]): string =
  ## Debug/testing helper for GEN-017 groundwork.
  ## Serializes via the direct-position string-only seq writer.
  const fieldOverhead = typeStringOnlyFieldOverhead(default(T))
  when fieldOverhead < 0:
    {.error: "debugSerializeStringOnlySeqDirect requires an object with only string fields".}
  else:
    let totalStrings = checkedJsonMul(countStringFieldsInType(default(T)), value.len,
      "too many strings to stage")
    var scan = initStringScanBatch(totalStrings)
    if value.len > 0:
      let items = cast[ptr UncheckedArray[T]](unsafeAddr value[0])
      var stringIdx = 0
      preScanStrings(items, value.len, scan.lengths, scan.firstUnsafe, stringIdx)
    var worstCaseBytes = 0
    var idx = 0
    while idx < totalStrings:
      worstCaseBytes = checkedJsonAdd(worstCaseBytes,
        worstJsonStringBytes(int(scan.lengths[idx]), 1), "JSON string batch too large to serialize")
      inc idx
    let exact = checkedJsonAdd(
      checkedJsonAdd(2, max(0, value.len - 1)),
      checkedJsonAdd(checkedJsonMul(value.len, checkedJsonAdd(2, fieldOverhead)),
        worstCaseBytes)
    )
    result = newStringUninit(max(2, exact))
    result.setLen(max(2, exact))
    var pos = 0
    writeStringOnlySeqObjectsDirect(result, pos, value)
    result.setLen(pos)

macro writeObjectFieldsCBatched(buf: typed, pos: typed, value: typed,
    floatBuf: typed, floatOff: typed, floatLen: typed, floatIdx: typed,
    intBuf: typed, intOff: typed, intLen: typed, intIdx: typed): untyped =
  ## Like writeObjectFieldsC but pulls pre-formatted floats and ints from batch buffers.
  ## Uses fused prefix+opening-quote for string fields.
  result = newStmtList()
  var first = true
  let fields = objectFieldEntriesEx(value)
  for (fieldName, access, fieldKind) in fields:
    let prefix = if first: "\"" & fieldName & "\":" else: ",\"" & fieldName & "\":"
    first = false
    let prefixLit = newLit(prefix)
    let fusedLit = newLit(prefix & "\"")
    if fieldKind in {jsfkJsonSafeString, jsfkAsciiSafeString}:
      result.add(newCall(bindSym"cPutLit", buf, pos, fusedLit))
      result.add(newCall(bindSym"cPutStrUnescapedBody", buf, pos,
        newCall(bindSym"rawString", access)))
    else:
      result.add(quote do:
        when typeof(`access`) is string:
          cPutLit(`buf`, `pos`, `fusedLit`)
          cPutJsonBody(`buf`, `pos`, `access`)
        elif typeof(`access`) is bool:
          cPutLit(`buf`, `pos`, `prefixLit`)
          writeValueC(`buf`, `pos`, `access`)
        elif typeof(`access`) is SomeInteger:
          cPutLit(`buf`, `pos`, `prefixLit`)
          # Pull from pre-formatted int batch
          block:
            let ii = `intIdx`
            let ilen = int(`intLen`[ii])
            let ioff = int(`intOff`[ii])
            copyMem(addr `buf`[`pos`], addr `intBuf`[ioff], ilen)
            `pos` += ilen
            inc `intIdx`
        elif typeof(`access`) is SomeFloat:
          cPutLit(`buf`, `pos`, `prefixLit`)
          # Pull from pre-formatted float batch
          block:
            let fi = `floatIdx`
            let flen = int(`floatLen`[fi])
            let foff = int(`floatOff`[fi])
            copyMem(addr `buf`[`pos`], addr `floatBuf`[foff], flen)
            `pos` += flen
            inc `floatIdx`
        elif typeof(`access`) is seq[string]:
          cPutLit(`buf`, `pos`, `prefixLit`)
          `buf`[`pos`] = '['; inc `pos`
          var idx = 0
          while idx < `access`.len:
            if idx > 0:
              `buf`[`pos`] = ','; inc `pos`
            cPutJsonEscaped(`buf`, `pos`, `access`[idx])
            inc idx
          `buf`[`pos`] = ']'; inc `pos`
        elif typeof(`access`) is seq[SomeInteger]:
          cPutLit(`buf`, `pos`, `prefixLit`)
          ensureRoom(`buf`, `pos`, cursorRoomForEstimate(estimateJsonSize(`access`)))
          `buf`[`pos`] = '['; inc `pos`
          var idx = 0
          while idx < `access`.len:
            if idx > 0:
              `buf`[`pos`] = ','; inc `pos`
            cPutInt(`buf`, `pos`, `access`[idx])
            inc idx
          `buf`[`pos`] = ']'; inc `pos`
        else:
          cPutLit(`buf`, `pos`, `prefixLit`)
          writeValueC(`buf`, `pos`, `access`)
      )

proc writeValueC[T: object](buf: var string, pos: var int, value: seq[T]) =
  ensureRoom(buf, pos, cursorRoomForEstimate(estimateJsonSize(value)))
  buf[pos] = '['; inc pos
  if value.len > 0:
    let items = cast[ptr UncheckedArray[T]](unsafeAddr value[0])
    discard  # Buffer pre-allocated in serializeDirect
    # Use batched path when the type has float or int fields
    when countFloatFieldsInType(items[0]) > 0 or countIntFieldsInType(items[0]) > 0:
      # Float batch
      when countFloatFieldsInType(items[0]) > 0:
        let numFloats = checkedJsonMul(countFloatFieldsInType(items[0]), value.len,
          "too many floats to serialize")
        var fBatch = initFloatBatch(numFloats)
        var floatIdx = 0
        preformatFloats(items, value.len, fBatch.buf, fBatch.offsets, fBatch.lens, floatIdx)
        floatIdx = 0
      else:
        var fBatch = initFloatBatch(0)
        var floatIdx = 0
      # Int batch
      when countIntFieldsInType(items[0]) > 0:
        let numInts = checkedJsonMul(countIntFieldsInType(items[0]), value.len,
          "too many integers to serialize")
        var iBatch = initIntBatch(numInts)
        var intIdx = 0
        preformatInts(items, value.len, iBatch.buf, iBatch.offsets, iBatch.lens, intIdx)
        intIdx = 0
      else:
        var iBatch = initIntBatch(0)
        var intIdx = 0
      var idx = 0
      while idx < value.len:
        if idx > 0:
          buf[pos] = ','; inc pos
        buf[pos] = '{'; inc pos
        writeObjectFieldsCBatched(buf, pos, items[idx],
                                   fBatch.buf, fBatch.offsets, fBatch.lens, floatIdx,
                                   iBatch.buf, iBatch.offsets, iBatch.lens, intIdx)
        buf[pos] = '}'; inc pos
        inc idx
    else:
      var idx = 0
      while idx < value.len:
        if idx > 0:
          buf[pos] = ','; inc pos
        buf[pos] = '{'; inc pos
        writeObjectFieldsC(buf, pos, items[idx])
        buf[pos] = '}'; inc pos
        inc idx
  buf[pos] = ']'; inc pos

proc writeValueC(buf: var string, pos: var int, value: seq[JsonSafeString]) =
  ensureRoom(buf, pos, cursorRoomForEstimate(estimateJsonSize(value)))
  buf[pos] = '['; inc pos
  if value.len > 0:
    let items = cast[ptr UncheckedArray[JsonSafeString]](unsafeAddr value[0])
    var idx = 0
    while idx < value.len:
      if idx > 0:
        buf[pos] = ','; inc pos
      cPutStrUnescaped(buf, pos, rawString(items[idx]))
      inc idx
  buf[pos] = ']'; inc pos

proc writeValueC(buf: var string, pos: var int, value: seq[JsonAsciiSafeString]) =
  ensureRoom(buf, pos, cursorRoomForEstimate(estimateJsonSize(value)))
  buf[pos] = '['; inc pos
  if value.len > 0:
    let items = cast[ptr UncheckedArray[JsonAsciiSafeString]](unsafeAddr value[0])
    var idx = 0
    while idx < value.len:
      if idx > 0:
        buf[pos] = ','; inc pos
      cPutStrUnescaped(buf, pos, rawString(items[idx]))
      inc idx
  buf[pos] = ']'; inc pos

proc writeValueC[T: ref object](buf: var string, pos: var int, value: T) =
  if value == nil:
    cPutNull(buf, pos)
  else:
    writeValueC(buf, pos, value[])

proc writeValueC[T: object](buf: var string, pos: var int, value: T) =
  buf[pos] = '{'; inc pos
  writeObjectFieldsC(buf, pos, value)
  buf[pos] = '}'; inc pos

proc writeSeqObjectRootC[T: object](buf: var string, pos: var int, value: seq[T])
proc writeTableObjectRootC[T: object](buf: var string, pos: var int, value: Table[string, T])
proc writeOrderedTableObjectRootC[T: object](buf: var string, pos: var int, value: OrderedTable[string, T])
proc writeNumericTreeRootC[T](buf: var string, pos: var int, value: T)

proc writeRootValueC[T](buf: var string, pos: var int, value: T) =
  writeValueC(buf, pos, value)

proc writeRootValueC[T: object](buf: var string, pos: var int, value: seq[T]) =
  writeSeqObjectRootC(buf, pos, value)

proc writeRootValueC[T: object](buf: var string, pos: var int, value: Table[string, T]) =
  writeTableObjectRootC(buf, pos, value)

proc writeRootValueC[T: object](buf: var string, pos: var int, value: OrderedTable[string, T]) =
  writeOrderedTableObjectRootC(buf, pos, value)

proc writeSeqObjectRootC[T: object](buf: var string, pos: var int, value: seq[T]) =
  ## Explicit root hook for top-level seq[object] serializers.
  ## Keeps the current measured-good row-order writer while allowing future
  ## shape-specialized routing to hang off the root dispatcher.
  when typeSafeStringOnlyFieldOverhead(default(T)) >= 0:
    writeSafeStringOnlySeqObjectsC(buf, pos, value)
  else:
    writeValueC(buf, pos, value)

proc writeTableObjectRootC[T: object](buf: var string, pos: var int, value: Table[string, T]) =
  when typeSafeStringOnlyFieldOverhead(default(T)) >= 0:
    writeSafeStringOnlyTableObjectsC(buf, pos, value)
  else:
    writeValueC(buf, pos, value)

proc writeOrderedTableObjectRootC[T: object](buf: var string, pos: var int, value: OrderedTable[string, T]) =
  when typeSafeStringOnlyFieldOverhead(default(T)) >= 0:
    writeSafeStringOnlyTableObjectsC(buf, pos, value)
  else:
    writeValueC(buf, pos, value)

proc writeNumericTreeRootC[T](buf: var string, pos: var int, value: T) =
  ## Explicit root hook for fixed-depth numeric tree classes.
  when T is seq[seq[seq[float64]]]:
    buf[pos] = '['
    inc pos
    if value.len > 0:
      let level1 = cast[ptr UncheckedArray[seq[seq[float64]]]](unsafeAddr value[0])
      var i = 0
      while i < value.len:
        if i > 0:
          buf[pos] = ','
          inc pos
        let ringGroup = level1[i]
        buf[pos] = '['
        inc pos
        if ringGroup.len > 0:
          let level2 = cast[ptr UncheckedArray[seq[float64]]](unsafeAddr ringGroup[0])
          var j = 0
          while j < ringGroup.len:
            if j > 0:
              buf[pos] = ','
              inc pos
            writeValueC(buf, pos, level2[j])
            inc j
        buf[pos] = ']'
        inc pos
        inc i
    buf[pos] = ']'
    inc pos
  elif T is seq[seq[seq[seq[float64]]]]:
    buf[pos] = '['
    inc pos
    if value.len > 0:
      let level0 = cast[ptr UncheckedArray[seq[seq[seq[float64]]]]](unsafeAddr value[0])
      var i = 0
      while i < value.len:
        if i > 0:
          buf[pos] = ','
          inc pos
        let poly = level0[i]
        buf[pos] = '['
        inc pos
        if poly.len > 0:
          let level1 = cast[ptr UncheckedArray[seq[seq[float64]]]](unsafeAddr poly[0])
          var j = 0
          while j < poly.len:
            if j > 0:
              buf[pos] = ','
              inc pos
            let ringGroup = level1[j]
            buf[pos] = '['
            inc pos
            if ringGroup.len > 0:
              let level2 = cast[ptr UncheckedArray[seq[float64]]](unsafeAddr ringGroup[0])
              var k = 0
              while k < ringGroup.len:
                if k > 0:
                  buf[pos] = ','
                  inc pos
                writeValueC(buf, pos, level2[k])
                inc k
            buf[pos] = ']'
            inc pos
            inc j
        buf[pos] = ']'
        inc pos
        inc i
    buf[pos] = ']'
    inc pos
  else:
    writeValueC(buf, pos, value)

template writeSerializeRoot(buf: var string, pos: var int, value: typed) =
  when selectedSerializeRootShape(typeof(value)) == jsrsNumericTree:
    writeNumericTreeRootC(buf, pos, value)
  else:
    writeRootValueC(buf, pos, value)

## Serializes a value into an existing buffer, resizing it to fit.
proc serializeDirectInto*[T](buf: var string, value: T) =
  ## Serialize into an existing buffer, reusing its allocation.
  ## The buffer is resized to fit; pass a pre-allocated string for zero-alloc.
  let estimated = estimateJsonSize(value)
  let cap = initialCapacityForSerialize(estimated)
  if buf.len < cap:
    buf.setLen(cap)
  var pos = 0
  writeSerializeRoot(buf, pos, value)
  buf.setLen(pos)

## Serializes a value to a newly allocated JSON string.
proc serializeDirect*[T](value: T): string =
  let estimated = estimateJsonSize(value)
  let cap = initialCapacityForSerialize(estimated)
  result = newStringUninit(cap)
  var pos = 0
  writeSerializeRoot(result, pos, value)
  result.setLen(pos)

## Deserializes a JSON string into a value of type T, rejecting trailing data.
proc deserializeDirect*[T](json: string, _: typedesc[T]): T =
  jsonParseDepth = 0
  var index = 0
  parseValue(json, index, result)
  eatSpace(json, index)
  if index != json.len:
    jsonError("trailing data", index)

## Returns true if ``json`` is syntactically valid JSON; walks every token with the direct engine.
proc isValidJsonDirect*(json: string): bool =
  try:
    var index = 0
    eatSpace(json, index)
    skipJsonValue(json, index)
    eatSpace(json, index)
    index == json.len
  except CatchableError:
    false

when defined(release):
  {.pop.}
