{.push warning[UnusedImport]: off.}
import std/[math, options, strutils, tables, unittest]
{.pop.}

import ../direct_engine

type
  Simple = object
    a: int
    b: float64
    c: string

  Nested = object
    inner: Simple
    tag: string

  WithOption = object
    x: Option[int]
    y: Option[string]

  WithSeq = object
    items: seq[int]

  WithNullable = object
    name: string
    items: seq[int]

  MultiField = object
    alpha: int
    bravo: string
    charlie: float64
    delta: bool

  Color = enum
    red, green, blue

  WithEnum = object
    color: Color

proc dd[T](json: string, _: typedesc[T]): T =
  deserializeDirect(json, T)

proc sd[T](value: T): string =
  serializeDirect(value)

proc expectReject(json: string) =
  var i = 0
  var raised = false
  try:
    skipJsonValue(json, i)
  except JsonError:
    raised = true
  check raised

proc expectRejectParse[T](json: string, _: typedesc[T]) =
  var raised = false
  try:
    discard dd(json, T)
  except JsonError:
    raised = true
  check raised

# ─────────────────────────────────────────────────────────────
# Number parsing edge cases
# ─────────────────────────────────────────────────────────────

suite "numbers – zero variants":
  test "0 as int":
    check dd("0", int) == 0
  test "-0 as int":
    check dd("-0", int) == 0
  test "0 as float":
    check dd("0", float64) == 0.0
  test "-0 as float":
    let v = dd("-0", float64)
    check v == 0.0
  test "-0.0 as float":
    let v = dd("-0.0", float64)
    check v == 0.0
    check classify(v) == fcNegZero
  test "0.0 as float":
    check dd("0.0", float64) == 0.0
  test "0e0 as float":
    check dd("0e0", float64) == 0.0

suite "numbers – integers at boundaries":
  test "max int64":
    check dd("9223372036854775807", int64) == high(int64)
  test "min int64":
    check dd("-9223372036854775808", int64) == low(int64)
  test "max uint64":
    check dd("18446744073709551615", uint64) == high(uint64)
  test "int64 overflow positive":
    expectRejectParse("9223372036854775808", int64)
  test "int64 overflow negative":
    expectRejectParse("-9223372036854775809", int64)
  test "uint64 overflow":
    expectRejectParse("18446744073709551616", uint64)
  test "int8 range":
    check dd("127", int8) == 127'i8
    check dd("-128", int8) == -128'i8
  test "int8 overflow":
    expectRejectParse("128", int8)
    expectRejectParse("-129", int8)
  test "uint8 range":
    check dd("255", uint8) == 255'u8
    check dd("0", uint8) == 0'u8
  test "uint8 overflow":
    expectRejectParse("256", uint8)
  test "int16 range":
    check dd("32767", int16) == high(int16)
    check dd("-32768", int16) == low(int16)
  test "int32 range":
    check dd("2147483647", int32) == high(int32)
    check dd("-2147483648", int32) == low(int32)
  test "single digit integers":
    for i in 0..9:
      check dd($i, int) == i
  test "negative single digit":
    for i in 1..9:
      check dd("-" & $i, int) == -i

suite "numbers – large and small floats":
  test "1e308":
    check dd("1e308", float64) == 1e308
  test "very small positive":
    check dd("5e-324", float64) == 5e-324
  test "1e-308 (subnormal boundary)":
    check dd("1e-308", float64) == 1e-308
  test "2.2250738585072014e-308 (min normal)":
    check dd("2.2250738585072014e-308", float64) == 2.2250738585072014e-308
  test "1.7976931348623157e+308 (max float64)":
    check dd("1.7976931348623157e+308", float64) == 1.7976931348623157e+308
  test "negative exponent":
    check dd("1.23e-4", float64) == 1.23e-4
  test "positive exponent with +":
    check dd("1.5E+10", float64) == 1.5e10
  test "float with many decimal digits":
    check dd("3.141592653589793", float64) == 3.141592653589793
  test "float32 parse":
    check dd("3.14", float32) == 3.14'f32

suite "numbers – rejection of invalid forms":
  test "leading zeros: 007":
    expectReject("007")
  test "leading zeros: 00":
    expectReject("00")
  test "leading zeros: 01.5":
    expectReject("01.5")
  test "leading zeros: -007":
    expectReject("-007")
  test "bare fraction: .5":
    expectReject(".5")
  test "bare exponent: e10":
    expectReject("e10")
  test "trailing dot: 1.":
    expectReject("1.")
  test "trailing e: 1e":
    expectReject("1e")
  test "trailing E+: 1E+":
    expectReject("1E+")
  test "trailing e-: 1e-":
    expectReject("1e-")
  test "leading +: +1":
    expectReject("+1")
  test "leading +: +0":
    expectRejectParse("+0", float64)
  test "NaN literal":
    expectReject("NaN")
  test "Infinity literal":
    expectReject("Infinity")
  test "-Infinity literal":
    expectReject("-Infinity")
  test "hex number: 0x1F":
    expectRejectParse("0x1F", int)
  test "octal: 0o17":
    expectRejectParse("0o17", int)
  test "just minus: -":
    expectReject("-")
  test "minus then non-digit: -a":
    expectReject("-a")
  test "double minus: --1":
    expectReject("--1")

# ─────────────────────────────────────────────────────────────
# String parsing
# ─────────────────────────────────────────────────────────────

suite "strings – basic escape sequences":
  test "escaped quote":
    check dd("\"hello\\\"world\"", string) == "hello\"world"
  test "escaped backslash":
    check dd("\"back\\\\slash\"", string) == "back\\slash"
  test "escaped forward slash":
    check dd("\"a\\/b\"", string) == "a/b"
  test "escaped backspace":
    check dd("\"a\\bb\"", string) == "a\bb"
  test "escaped form feed":
    check dd("\"a\\fb\"", string) == "a\fb"
  test "escaped newline":
    check dd("\"a\\nb\"", string) == "a\nb"
  test "escaped carriage return":
    check dd("\"a\\rb\"", string) == "a\rb"
  test "escaped tab":
    check dd("\"a\\tb\"", string) == "a\tb"
  test "multiple escapes in one string":
    check dd("\"\\n\\t\\r\\\\\\\"\"", string) == "\n\t\r\\\""
  test "empty string":
    check dd("\"\"", string) == ""
  test "null is rejected for non-nullable string":
    expectRejectParse("null", string)

suite "strings – unicode escapes":
  test "ASCII via \\u":
    check dd("\"\\u0041\"", string) == "A"
  test "null char via \\u0000":
    check dd("\"\\u0000\"", string) == "\x00"
  test "non-ASCII BMP: \\u00E9 (é)":
    check dd("\"\\u00E9\"", string) == "\xC3\xA9"
  test "CJK character: \\u4E16 (世)":
    check dd("\"\\u4E16\"", string) == "世"
  test "surrogate pair: U+1F512 (🔒)":
    check dd("\"\\uD83D\\uDD12\"", string) == "\xF0\x9F\x94\x92"
  test "surrogate pair: U+1F600 (😀)":
    check dd("\"\\uD83D\\uDE00\"", string) == "\xF0\x9F\x98\x80"
  test "surrogate pair: U+10000":
    check dd("\"\\uD800\\uDC00\"", string) == "\xF0\x90\x80\x80"
  test "surrogate pair: U+10FFFF":
    check dd("\"\\uDBFF\\uDFFF\"", string) == "\xF4\x8F\xBF\xBF"
  test "lone high surrogate is rejected":
    expectRejectParse("\"\\uD800\"", string)
  test "lone high surrogate at end":
    expectRejectParse("\"\\uD800x\"", string)
  test "lone low surrogate is rejected":
    expectRejectParse("\"\\uDC00\"", string)
  test "high surrogate not followed by low":
    expectRejectParse("\"\\uD800\\u0041\"", string)
  test "invalid hex in \\u escape":
    expectRejectParse("\"\\uXXXX\"", string)
  test "truncated \\u escape":
    expectRejectParse("\"\\u00\"", string)
  test "mixed escapes and unicode":
    let v = dd("\"hello\\u0020\\nworld\"", string)
    check v == "hello \nworld"
  test "lowercase hex":
    check dd("\"\\u00e9\"", string) == "\xC3\xA9"
  test "uppercase hex":
    check dd("\"\\u00E9\"", string) == "\xC3\xA9"

suite "strings – control characters":
  test "all control chars 0x00..0x1F rejected unescaped":
    for code in 0x00 .. 0x1F:
      let payload = "\"x" & chr(code) & "y\""
      var raised = false
      try:
        discard dd(payload, string)
      except JsonError:
        raised = true
      checkpoint("control char 0x" & toHex(code, 2))
      check raised
  test "DEL (0x7F) accepted":
    let payload = "\"del" & chr(0x7F) & "char\""
    check dd(payload, string) == "del" & chr(0x7F) & "char"
  test "escaped control chars via \\u00xx":
    check dd("\"\\u000A\"", string) == "\n"
    check dd("\"\\u000D\"", string) == "\r"
    check dd("\"\\u0009\"", string) == "\t"

suite "strings – invalid escapes":
  test "invalid escape \\a":
    expectRejectParse("\"\\a\"", string)
  test "invalid escape \\x":
    expectRejectParse("\"\\x\"", string)
  test "invalid escape \\0":
    expectRejectParse("\"\\0\"", string)
  test "backslash at end of string":
    expectRejectParse("\"hello\\", string)
  test "unterminated string":
    expectRejectParse("\"hello", string)

suite "strings – long strings crossing SWAR boundaries":
  test "string exactly 8 bytes (one SWAR word)":
    check dd("\"abcdefgh\"", string) == "abcdefgh"
  test "string 7 bytes":
    check dd("\"abcdefg\"", string) == "abcdefg"
  test "string 9 bytes (crosses SWAR boundary)":
    check dd("\"abcdefghi\"", string) == "abcdefghi"
  test "string 16 bytes":
    let s = "abcdefghijklmnop"
    check dd("\"" & s & "\"", string) == s
  test "string 17 bytes":
    let s = "abcdefghijklmnopq"
    check dd("\"" & s & "\"", string) == s
  test "escape at SWAR boundary (pos 7)":
    let json = "\"1234567\\n89\""
    check dd(json, string) == "1234567\n89"
  test "escape at SWAR boundary (pos 8)":
    let json = "\"12345678\\n90\""
    check dd(json, string) == "12345678\n90"
  test "long string with escape near end":
    let prefix = repeat('a', 100)
    let json = "\"" & prefix & "\\n\""
    check dd(json, string) == prefix & "\n"
  test "very long plain string":
    let s = repeat('x', 4096)
    check dd("\"" & s & "\"", string) == s

# ─────────────────────────────────────────────────────────────
# UTF-8 edge cases (raw bytes in strings)
# ─────────────────────────────────────────────────────────────

suite "strings – UTF-8 multi-byte sequences":
  test "2-byte sequence (Latin-1 supplement)":
    let json = "\"caf\xC3\xA9\""
    check dd(json, string) == "caf\xC3\xA9"
  test "3-byte sequence (CJK)":
    let json = "\"\xE4\xB8\x96\xE7\x95\x8C\""
    check dd(json, string) == "\xE4\xB8\x96\xE7\x95\x8C"
  test "4-byte sequence (emoji)":
    let json = "\"\xF0\x9F\x98\x80\""
    check dd(json, string) == "\xF0\x9F\x98\x80"
  test "mixed ASCII and multibyte":
    let json = "\"hello \xC3\xA9 world \xF0\x9F\x98\x80\""
    check dd(json, string) == "hello \xC3\xA9 world \xF0\x9F\x98\x80"

# ─────────────────────────────────────────────────────────────
# Boolean parsing
# ─────────────────────────────────────────────────────────────

suite "booleans":
  test "true":
    check dd("true", bool) == true
  test "false":
    check dd("false", bool) == false
  test "True rejected":
    expectRejectParse("True", bool)
  test "FALSE rejected":
    expectRejectParse("FALSE", bool)
  test "1 as bool rejected":
    expectRejectParse("1", bool)
  test "tru rejected (truncated)":
    expectRejectParse("tru", bool)
  test "fals rejected (truncated)":
    expectRejectParse("fals", bool)

# ─────────────────────────────────────────────────────────────
# Array parsing
# ─────────────────────────────────────────────────────────────

suite "arrays – basic":
  test "empty array":
    check dd("[]", seq[int]).len == 0
  test "single element":
    check dd("[42]", seq[int]) == @[42]
  test "multiple elements":
    check dd("[1,2,3]", seq[int]) == @[1, 2, 3]
  test "with whitespace":
    check dd("[ 1 , 2 , 3 ]", seq[int]) == @[1, 2, 3]
  test "string array":
    check dd("""["a","b","c"]""", seq[string]) == @["a", "b", "c"]
  test "bool array":
    check dd("[true,false,true]", seq[bool]) == @[true, false, true]
  test "float array":
    check dd("[1.5,2.5,3.5]", seq[float64]) == @[1.5, 2.5, 3.5]
  test "null is rejected for non-nullable seq":
    expectRejectParse("null", seq[int])

suite "arrays – nested":
  test "array of arrays":
    check dd("[[1,2],[3,4]]", seq[seq[int]]) == @[@[1, 2], @[3, 4]]
  test "empty nested arrays":
    let v = dd("[[],[]]", seq[seq[int]])
    check v.len == 2
    check v[0].len == 0
    check v[1].len == 0
  test "deeply nested arrays":
    let json = "[[[[1]]]]"
    check dd(json, seq[seq[seq[seq[int]]]]) == @[@[@[@[1]]]]

suite "arrays – error cases":
  test "unterminated array":
    expectRejectParse("[1,2", seq[int])
  test "trailing comma in array":
    expectRejectParse("[1,2,]", seq[int])
  test "missing comma":
    expectRejectParse("[1 2]", seq[int])
  test "leading comma":
    expectRejectParse("[,1]", seq[int])

# ─────────────────────────────────────────────────────────────
# Object parsing
# ─────────────────────────────────────────────────────────────

suite "objects – basic":
  test "empty object":
    let v = dd("{}", Simple)
    check v.a == 0
    check v.b == 0.0
    check v.c == ""
  test "simple object":
    let v = dd("""{"a":1,"b":2.5,"c":"hello"}""", Simple)
    check v.a == 1
    check v.b == 2.5
    check v.c == "hello"
  test "with whitespace":
    let v = dd("""{ "a" : 1 , "b" : 2.5 , "c" : "hello" }""", Simple)
    check v.a == 1
    check v.b == 2.5
    check v.c == "hello"
  test "unknown fields are skipped":
    let v = dd("""{"a":1,"unknown":99,"b":2.5,"c":"x"}""", Simple)
    check v.a == 1
    check v.b == 2.5
    check v.c == "x"
  test "fields in different order":
    let v = dd("""{"c":"hi","a":5,"b":1.0}""", Simple)
    check v.a == 5
    check v.c == "hi"
  test "duplicate keys (last wins)":
    let v = dd("""{"a":1,"a":2}""", Simple)
    check v.a == 2

suite "objects – nested":
  test "nested object":
    let v = dd("""{"inner":{"a":1,"b":2.0,"c":"x"},"tag":"test"}""", Nested)
    check v.inner.a == 1
    check v.inner.b == 2.0
    check v.inner.c == "x"
    check v.tag == "test"
  test "null nested object fields default":
    let v = dd("""{"tag":"t"}""", Nested)
    check v.inner.a == 0
    check v.tag == "t"

suite "objects – with optional fields":
  test "Option some":
    let v = dd("""{"x":42,"y":"hello"}""", WithOption)
    check v.x == some(42)
    check v.y == some("hello")
  test "Option none via null":
    let v = dd("""{"x":null,"y":null}""", WithOption)
    check v.x.isNone
    check v.y.isNone
  test "Option missing field":
    let v = dd("""{}""", WithOption)
    check v.x.isNone
    check v.y.isNone

suite "objects – Table parsing":
  test "empty table":
    let t = dd("{}", Table[string, int])
    check t.len == 0
  test "simple table":
    let t = dd("""{"a":1,"b":2}""", Table[string, int])
    check t["a"] == 1
    check t["b"] == 2
  test "table with string values":
    let t = dd("""{"key":"val"}""", Table[string, string])
    check t["key"] == "val"
  test "duplicate keys in table (last wins)":
    let t = dd("""{"a":1,"a":2}""", Table[string, int])
    check t["a"] == 2
  test "many keys in table":
    var json = "{"
    for i in 0..<50:
      if i > 0: json.add(",")
      json.add("\"k" & $i & "\":" & $i)
    json.add("}")
    let t = dd(json, Table[string, int])
    check t.len == 50
    check t["k0"] == 0
    check t["k49"] == 49
  test "ordered table preserves order":
    let t = dd("""{"c":3,"a":1,"b":2}""", OrderedTable[string, int])
    var keys: seq[string]
    for k in t.keys:
      keys.add(k)
    check keys == @["c", "a", "b"]

suite "objects – error cases":
  test "unterminated object":
    expectReject("{\"a\":1")
    expectRejectParse("{\"a\":1", Table[string, int])
    expectRejectParse("{\"a\":1", OrderedTable[string, int])
  test "missing colon":
    expectReject("{\"a\" 1}")
  test "trailing comma":
    expectReject("{\"a\":1,}")
  test "non-string key":
    expectReject("{42:1}")
  test "null key":
    expectReject("{null:1}")
  test "missing value":
    expectReject("{\"a\":}")

# ─────────────────────────────────────────────────────────────
# Enum parsing
# ─────────────────────────────────────────────────────────────

suite "enums":
  test "parse valid enum":
    let v = dd("""{"color":"red"}""", WithEnum)
    check v.color == red
  test "parse another enum value":
    let v = dd("""{"color":"blue"}""", WithEnum)
    check v.color == blue
  test "invalid enum value":
    expectRejectParse("""{"color":"purple"}""", WithEnum)

# ─────────────────────────────────────────────────────────────
# Ref objects and Option
# ─────────────────────────────────────────────────────────────

type
  RefObj = ref object
    x: int

suite "ref objects":
  test "parse ref object":
    let v = dd("""{"x":42}""", RefObj)
    check v != nil
    check v.x == 42
  test "null ref object":
    let v = dd("null", RefObj)
    check v == nil

suite "standalone Option types":
  test "Option[int] some":
    check dd("42", Option[int]) == some(42)
  test "Option[int] null":
    check dd("null", Option[int]).isNone
  test "Option[string] some":
    check dd("\"hi\"", Option[string]) == some("hi")
  test "Option[string] null":
    check dd("null", Option[string]).isNone

# ─────────────────────────────────────────────────────────────
# Serialization
# ─────────────────────────────────────────────────────────────

suite "serialization – primitives":
  test "int":
    check sd(42) == "42"
  test "negative int":
    check sd(-1) == "-1"
  test "zero":
    check sd(0) == "0"
  test "true":
    check sd(true) == "true"
  test "false":
    check sd(false) == "false"
  test "empty string":
    check sd("") == "\"\""
  test "simple string":
    check sd("hello") == "\"hello\""
  test "string with quotes":
    check sd("say \"hi\"") == "\"say \\\"hi\\\"\""
  test "string with backslash":
    check sd("a\\b") == "\"a\\\\b\""
  test "string with newline":
    check sd("a\nb") == "\"a\\nb\""
  test "string with tab":
    check sd("a\tb") == "\"a\\tb\""
  test "string with carriage return":
    check sd("a\rb") == "\"a\\rb\""
  test "string with control chars":
    check sd("\x01\x1F") == "\"\\u0001\\u001f\""
  test "float64 basic":
    let s = sd(3.14)
    check s.len > 0
    check parseFloat(s) == 3.14

suite "serialization – NaN/Infinity rejection":
  test "NaN":
    expect JsonError:
      discard sd(NaN)
  test "Inf":
    expect JsonError:
      discard sd(Inf)
  test "NegInf":
    expect JsonError:
      discard sd(NegInf)

suite "serialization – objects":
  test "simple object":
    let v = Simple(a: 1, b: 2.5, c: "hi")
    let json = sd(v)
    let parsed = dd(json, Simple)
    check parsed.a == 1
    check parsed.b == 2.5
    check parsed.c == "hi"
  test "nested object round-trip":
    let v = Nested(inner: Simple(a: 10, b: 0.5, c: "test"), tag: "ok")
    let json = sd(v)
    let parsed = dd(json, Nested)
    check parsed.inner.a == 10
    check parsed.inner.c == "test"
    check parsed.tag == "ok"
  test "object with special chars in string":
    let v = Simple(a: 0, b: 0.0, c: "a\"b\\c\nd")
    let json = sd(v)
    let parsed = dd(json, Simple)
    check parsed.c == "a\"b\\c\nd"

suite "serialization – sequences":
  test "empty seq":
    check sd(newSeq[int]()) == "[]"
  test "int seq":
    check sd(@[1, 2, 3]) == "[1,2,3]"
  test "string seq":
    let json = sd(@["a", "b"])
    check dd(json, seq[string]) == @["a", "b"]
  test "nested seq":
    let json = sd(@[@[1, 2], @[3, 4]])
    check dd(json, seq[seq[int]]) == @[@[1, 2], @[3, 4]]

suite "serialization – tables":
  test "empty table":
    var t = initTable[string, int]()
    let json = sd(t)
    check json == "{}"
  test "table round-trip":
    var t = initTable[string, int]()
    t["a"] = 1
    t["b"] = 2
    let json = sd(t)
    let parsed = dd(json, Table[string, int])
    check parsed["a"] == 1
    check parsed["b"] == 2

# ─────────────────────────────────────────────────────────────
# Round-trip correctness
# ─────────────────────────────────────────────────────────────

suite "round-trip":
  test "simple object":
    let orig = Simple(a: 42, b: 3.14, c: "hello world")
    check dd(sd(orig), Simple).a == orig.a
    check dd(sd(orig), Simple).c == orig.c
  test "integer boundaries":
    check dd(sd(high(int64)), int64) == high(int64)
    check dd(sd(low(int64)), int64) == low(int64)
    check dd(sd(low(int64) + 1), int64) == low(int64) + 1
  test "string with all escape chars":
    let orig = "\"\\/\b\f\n\r\t"
    let json = sd(orig)
    check dd(json, string) == orig
  test "empty containers":
    check dd(sd(newSeq[int]()), seq[int]).len == 0
    var t = initTable[string, int]()
    check dd(sd(t), Table[string, int]).len == 0
  test "unicode string round-trip":
    let orig = "café 世界 🌍"
    let json = sd(orig)
    check dd(json, string) == orig
  test "deeply nested object round-trip":
    let v = Nested(inner: Simple(a: -1, b: -0.0, c: ""), tag: "")
    check dd(sd(v), Nested).inner.a == -1

# ─────────────────────────────────────────────────────────────
# serializeDirectInto (reusable buffer)
# ─────────────────────────────────────────────────────────────

suite "serializeDirectInto":
  test "basic usage":
    var buf = ""
    serializeDirectInto(buf, 42)
    check buf == "42"
  test "reuse buffer":
    var buf = ""
    serializeDirectInto(buf, "hello")
    check buf == "\"hello\""
    serializeDirectInto(buf, "world")
    check buf == "\"world\""
  test "object into buffer":
    var buf = ""
    serializeDirectInto(buf, Simple(a: 1, b: 2.0, c: "x"))
    let parsed = dd(buf, Simple)
    check parsed.a == 1

# ─────────────────────────────────────────────────────────────
# Error handling – truncated and malformed input
# ─────────────────────────────────────────────────────────────

suite "error handling – truncated input":
  test "empty string":
    expectReject("")
  test "just whitespace":
    expectReject("   ")
  test "truncated true":
    expectReject("tru")
  test "truncated false":
    expectReject("fals")
  test "truncated null":
    expectReject("nul")
  test "truncated string":
    expectReject("\"hello")
  test "truncated array":
    expectReject("[1,2")
  test "truncated object":
    expectReject("{\"a\":")

suite "error handling – trailing garbage":
  test "number then garbage":
    expect JsonError:
      discard dd("42abc", int)
  test "string then garbage":
    expect JsonError:
      discard dd("\"hello\"extra", string)
  test "object then garbage":
    expect JsonError:
      discard dd("""{"a":1}x""", Simple)
  test "array then garbage":
    expect JsonError:
      discard dd("[1,2]x", seq[int])
  test "true then garbage":
    expect JsonError:
      discard dd("truex", bool)
  test "trailing whitespace is ok":
    check dd("42  ", int) == 42
    check dd("\"hi\"  ", string) == "hi"

suite "error handling – invalid tokens":
  test "random word":
    expectReject("foobar")
  test "single open brace":
    expectReject("{")
  test "single open bracket":
    expectReject("[")
  test "bare comma":
    expectReject(",")
  test "bare colon":
    expectReject(":")
  test "bare close brace":
    expectReject("}")
  test "bare close bracket":
    expectReject("]")

# ─────────────────────────────────────────────────────────────
# Whitespace handling
# ─────────────────────────────────────────────────────────────

suite "whitespace":
  test "leading whitespace":
    check dd("  42", int) == 42
  test "trailing whitespace":
    check dd("42  ", int) == 42
  test "whitespace around object":
    let v = dd("  { \"a\" : 1 }  ", Simple)
    check v.a == 1
  test "tab and newline whitespace":
    check dd("\t\n42\r\n", int) == 42
  test "whitespace in array":
    check dd(" [ 1 , 2 ] ", seq[int]) == @[1, 2]

# ─────────────────────────────────────────────────────────────
# Maximum nesting depth
# ─────────────────────────────────────────────────────────────

suite "nesting depth":
  test "deeply nested arrays exceeding limit":
    var json = ""
    for i in 0..<513:
      json.add("[")
    json.add("1")
    for i in 0..<513:
      json.add("]")
    var idx = 0
    var raised = false
    try:
      skipJsonValue(json, idx)
    except JsonError:
      raised = true
    check raised

  test "deeply nested objects exceeding limit":
    var json = ""
    for i in 0..<513:
      json.add("{\"x\":")
    json.add("1")
    for i in 0..<513:
      json.add("}")
    var idx = 0
    var raised = false
    try:
      skipJsonValue(json, idx)
    except JsonError:
      raised = true
    check raised

  test "exactly at limit (512) succeeds":
    var json = ""
    for i in 0..<512:
      json.add("[")
    json.add("1")
    for i in 0..<512:
      json.add("]")
    var idx = 0
    skipJsonValue(json, idx)
    check idx == json.len

  test "moderate nesting succeeds":
    var json = ""
    for i in 0..<100:
      json.add("[")
    json.add("1")
    for i in 0..<100:
      json.add("]")
    var idx = 0
    skipJsonValue(json, idx)
    check idx == json.len

# ─────────────────────────────────────────────────────────────
# skipJsonValue coverage
# ─────────────────────────────────────────────────────────────

suite "skipJsonValue – all types":
  test "skip number":
    var i = 0
    skipJsonValue("42", i)
    check i == 2
  test "skip negative float":
    var i = 0
    skipJsonValue("-3.14e10", i)
    check i == 8
  test "skip string":
    var i = 0
    skipJsonValue("\"hello\"", i)
    check i == 7
  test "skip string with escapes":
    var i = 0
    skipJsonValue("\"he\\\"llo\"", i)
    check i == 9
  test "skip true":
    var i = 0
    skipJsonValue("true", i)
    check i == 4
  test "skip false":
    var i = 0
    skipJsonValue("false", i)
    check i == 5
  test "skip null":
    var i = 0
    skipJsonValue("null", i)
    check i == 4
  test "skip empty array":
    var i = 0
    skipJsonValue("[]", i)
    check i == 2
  test "skip nested array":
    var i = 0
    skipJsonValue("[[1],[2,3]]", i)
    check i == 11
  test "skip empty object":
    var i = 0
    skipJsonValue("{}", i)
    check i == 2
  test "skip complex object":
    var i = 0
    let json = """{"a":1,"b":[2,3],"c":{"d":"e"}}"""
    skipJsonValue(json, i)
    check i == json.len

# ─────────────────────────────────────────────────────────────
# Object key with escapes (slow path)
# ─────────────────────────────────────────────────────────────

suite "object keys with escape sequences":
  test "escaped key parsed correctly":
    let json = "{\"hello\\nworld\":\"val\"}"
    let t = dd(json, Table[string, string])
    check t["hello\nworld"] == "val"
  test "unicode escaped key":
    let json = "{\"\\u0041\":\"val\"}"
    let t = dd(json, Table[string, string])
    check t["A"] == "val"
  test "key with backslash":
    let json = "{\"a\\\\b\":\"val\"}"
    let t = dd(json, Table[string, string])
    check t["a\\b"] == "val"

# ─────────────────────────────────────────────────────────────
# MultiField objects (field dispatch coverage)
# ─────────────────────────────────────────────────────────────

suite "multi-field dispatch":
  test "all fields populated":
    let v = dd("""{"alpha":1,"bravo":"x","charlie":3.0,"delta":true}""", MultiField)
    check v.alpha == 1
    check v.bravo == "x"
    check v.charlie == 3.0
    check v.delta == true
  test "partial fields (rest default)":
    let v = dd("""{"bravo":"test"}""", MultiField)
    check v.alpha == 0
    check v.bravo == "test"
    check v.charlie == 0.0
    check v.delta == false
  test "unknown + known mixed":
    let v = dd("""{"alpha":5,"zzz":"ignored","delta":false}""", MultiField)
    check v.alpha == 5
    check v.delta == false

# ─────────────────────────────────────────────────────────────
# WithSeq objects
# ─────────────────────────────────────────────────────────────

suite "objects with seq fields":
  test "populated seq field":
    let v = dd("""{"items":[1,2,3]}""", WithSeq)
    check v.items == @[1, 2, 3]
  test "empty seq field":
    let v = dd("""{"items":[]}""", WithSeq)
    check v.items.len == 0
  test "null seq field is rejected":
    expectRejectParse("""{"items":null}""", WithSeq)

suite "objects with non-nullable string and seq fields":
  test "null string field is rejected":
    expectRejectParse("""{"name":null,"items":[]}""", WithNullable)
  test "null seq field is rejected while string is valid":
    expectRejectParse("""{"name":"ok","items":null}""", WithNullable)

# ─────────────────────────────────────────────────────────────
# Unsigned integers
# ─────────────────────────────────────────────────────────────

suite "unsigned integers":
  test "uint8":
    check dd("255", uint8) == 255'u8
  test "uint16":
    check dd("65535", uint16) == 65535'u16
  test "uint32":
    check dd("4294967295", uint32) == 4294967295'u32
  test "uint64 max":
    check dd("18446744073709551615", uint64) == high(uint64)
  test "uint64 zero":
    check dd("0", uint64) == 0'u64
  test "negative rejected for unsigned":
    expectRejectParse("-1", uint64)
  test "leading zeros rejected for unsigned":
    expectRejectParse("007", uint8)

# ─────────────────────────────────────────────────────────────
# Numbers with whitespace in different positions
# ─────────────────────────────────────────────────────────────

suite "numbers with surrounding whitespace":
  test "spaces before number in object value":
    let v = dd("{\"a\":  42}", Simple)
    check v.a == 42
  test "tabs before number":
    check dd("\t42", int) == 42
  test "newlines before number":
    check dd("\n\r\n42", int) == 42
