{.push warning[UnusedImport]: off.}
import std/[math, options, strutils, tables, unittest]
{.pop.}

import ../../nim_fastjson
import ../direct_engine

type
  Simple = object
    a: int
    b: float64
    c: string

  WithSeq = object
    items: seq[int]

  RefObj = ref object
    id: int

  Status = enum
    active, inactive

let fj = initFastJson()

proc directDeserialize[T](json: string, _: typedesc[T]): T =
  direct_engine.deserializeDirect(json, T)

proc expectDirectReject(json: string) =
  var i = 0
  var raised = false
  try:
    skipJsonValue(json, i)
  except nim_fastjson.JsonError:
    raised = true
  check raised

suite "RFC 8259 §6 – reject leading zeros in numbers":
  test "007 is rejected":
    expect nim_fastjson.JsonError:
      discard directDeserialize("007", int)

  test "01.5 is rejected":
    expect nim_fastjson.JsonError:
      discard directDeserialize("01.5", float64)

  test "00 is rejected":
    expect nim_fastjson.JsonError:
      discard directDeserialize("00", int)

  test "-007 is rejected":
    expect nim_fastjson.JsonError:
      discard directDeserialize("-007", float64)

  test "007 rejected via skipJsonValue":
    expectDirectReject("007")

  test "01.5 rejected via skipJsonValue":
    expectDirectReject("01.5")

  test "0 is accepted":
    check directDeserialize("0", int) == 0

  test "0.5 is accepted":
    check directDeserialize("0.5", float64) == 0.5

  test "-0 is accepted":
    check directDeserialize("-0", int) == 0

  test "-0.0 is accepted":
    check directDeserialize("-0.0", float64) == 0.0

suite "RFC 8259 §6 – require digit after decimal point":
  test "1. is rejected":
    expect nim_fastjson.JsonError:
      discard directDeserialize("1.", float64)

  test "0. is rejected":
    expect nim_fastjson.JsonError:
      discard directDeserialize("0.", float64)

  test "-5. is rejected":
    expect nim_fastjson.JsonError:
      discard directDeserialize("-5.", float64)

  test "1. rejected via skipJsonValue":
    expectDirectReject("1.")

  test "1.0 is accepted":
    check directDeserialize("1.0", float64) == 1.0

  test "0.123 is accepted":
    check directDeserialize("0.123", float64) == 0.123

suite "RFC 8259 §6 – large decimals do not overflow internal accumulators":
  test "large integer component without exponent parses via safe fallback":
    check directDeserialize("18446744073709551616.0", float64) == 18446744073709551616.0

  test "very large decimal without exponent stays finite and non-wrapped":
    let parsed = directDeserialize("999999999999999999999999999999.0", float64)
    check parsed > 9.0e29
    check parsed < Inf

  test "long fractional component preserves decimal magnitude":
    let parsed = directDeserialize("1.23456789012345678901234567890", float64)
    check parsed > 1.2345
    check parsed < 1.2346

suite "RFC 8259 §6 – require digit after exponent":
  test "1e is rejected":
    expect nim_fastjson.JsonError:
      discard directDeserialize("1e", float64)

  test "1E+ is rejected":
    expect nim_fastjson.JsonError:
      discard directDeserialize("1E+", float64)

  test "1e- is rejected":
    expect nim_fastjson.JsonError:
      discard directDeserialize("1e-", float64)

  test "2.5E is rejected":
    expect nim_fastjson.JsonError:
      discard directDeserialize("2.5E", float64)

  test "1e rejected via skipJsonValue":
    expectDirectReject("1e")

  test "1e10 is accepted":
    check directDeserialize("1e10", float64) == 1e10

  test "1E+2 is accepted":
    check directDeserialize("1E+2", float64) == 1E+2

  test "5e-3 is accepted":
    check directDeserialize("5e-3", float64) == 5e-3

  test "1.5E10 is accepted":
    check directDeserialize("1.5E10", float64) == 1.5E10

suite "RFC 8259 §6 – reject leading plus on numbers":
  test "+1 is rejected as float":
    expect nim_fastjson.JsonError:
      discard directDeserialize("+1.0", float64)

  test "+0 is rejected as float":
    expect nim_fastjson.JsonError:
      discard directDeserialize("+0", float64)

  test "+1 rejected via skipJsonValue":
    expectDirectReject("+1")

  test "positive number without plus is accepted":
    check directDeserialize("42", int) == 42

  test "negative number is accepted":
    check directDeserialize("-1", int) == -1

suite "RFC 8259 §6 – reject NaN and Infinity in serialization":
  test "NaN serialization raises JsonError":
    expect nim_fastjson.JsonError:
      discard fj.serialize(NaN)

  test "Inf serialization raises JsonError":
    expect nim_fastjson.JsonError:
      discard fj.serialize(Inf)

  test "NegInf serialization raises JsonError":
    expect nim_fastjson.JsonError:
      discard fj.serialize(NegInf)

  test "NaN in object field raises JsonError":
    expect nim_fastjson.JsonError:
      discard fj.serialize(Simple(a: 0, b: NaN, c: ""))

  test "Inf in object field raises JsonError":
    expect nim_fastjson.JsonError:
      discard fj.serialize(Simple(a: 0, b: Inf, c: ""))

  test "normal float serializes fine":
    let json = fj.serialize(3.14)
    check json.len > 0

suite "RFC 8259 §7 – SWAR fast path detects control chars":
  test "tab in string triggers SWAR detection":
    expect nim_fastjson.JsonError:
      discard directDeserialize("{\"c\":\"hello\tworld\"}", Simple)

  test "newline in string is rejected":
    expect nim_fastjson.JsonError:
      discard directDeserialize("{\"c\":\"line\nbreak\"}", Simple)

  test "carriage return in string is rejected":
    expect nim_fastjson.JsonError:
      discard directDeserialize("{\"c\":\"cr\rhere\"}", Simple)

  test "null byte in string is rejected":
    let payload = "{\"c\":\"has" & "\x00" & "null\"}"
    expect nim_fastjson.JsonError:
      discard directDeserialize(payload, Simple)

  test "BEL (0x07) in string is rejected":
    let payload = "{\"c\":\"bel" & "\x07" & "char\"}"
    expect nim_fastjson.JsonError:
      discard directDeserialize(payload, Simple)

  test "all control chars 0x01..0x1F in string are rejected":
    for code in 0x01 .. 0x1F:
      let payload = "{\"c\":\"x" & chr(code) & "y\"}"
      var raised = false
      try:
        discard directDeserialize(payload, Simple)
      except nim_fastjson.JsonError:
        raised = true
      check raised

  test "escaped control chars are accepted":
    let v = directDeserialize("{\"c\":\"hello\\nworld\"}", Simple)
    check v.c == "hello\nworld"

  test "escaped tab is accepted":
    let v = directDeserialize("{\"c\":\"hello\\tworld\"}", Simple)
    check v.c == "hello\tworld"

suite "RFC 8259 §7 – parseUnicodeEscape raises JsonError":
  test "invalid hex in unicode escape raises JsonError not ValueError":
    expect nim_fastjson.JsonError:
      discard directDeserialize("\"\\uXXXX\"", string)

  test "truncated unicode escape raises JsonError":
    expect nim_fastjson.JsonError:
      discard directDeserialize("\"\\u00\"", string)

  test "invalid hex digit g raises JsonError":
    expect nim_fastjson.JsonError:
      discard directDeserialize("\"\\u00g0\"", string)

  test "valid unicode escape is accepted":
    let v = directDeserialize("\"\\u0041\"", string)
    check v == "A"

  test "surrogate pair is accepted":
    let v = directDeserialize("\"\\uD83D\\uDD12\"", string)
    check v == "\xF0\x9F\x94\x92"

suite "RFC 8259 §7 – reject unescaped control characters in strings":
  test "each control char 0x00..0x1F is rejected in raw string parse":
    for code in 0x00 .. 0x1F:
      let payload = "\"before" & chr(code) & "after\""
      var raised = false
      try:
        discard directDeserialize(payload, string)
      except nim_fastjson.JsonError:
        raised = true
      checkpoint("control char 0x" & toHex(code, 2))
      check raised

  test "space (0x20) in string is accepted":
    let v = directDeserialize("\"hello world\"", string)
    check v == "hello world"

  test "DEL (0x7F) in string is accepted":
    let v = directDeserialize("\"del\x7Fchar\"", string)
    check v == "del\x7Fchar"

suite "RFC 8259 §8.1 – reject invalid UTF-8 in raw strings":
  test "invalid two-byte sequence is rejected in raw string fast path":
    expect nim_fastjson.JsonError:
      discard directDeserialize("\"bad\xC3\x28\"", string)

  test "truncated multibyte sequence is rejected in raw string fast path":
    expect nim_fastjson.JsonError:
      discard directDeserialize("\"bad\xE2\x82\"", string)

  test "invalid UTF-8 is rejected after escape slow path copies spans":
    expect nim_fastjson.JsonError:
      discard directDeserialize("\"bad\xC3\x28\\n\"", string)

  test "invalid UTF-8 is rejected in object keys with escapes":
    expect nim_fastjson.JsonError:
      discard directDeserialize("{\"bad\xC3\x28\\n\":1}", Table[string, int])

suite "direct engine null handling":
  test "top-level non-nullable string rejects null":
    expect nim_fastjson.JsonError:
      discard directDeserialize("null", string)

  test "top-level non-nullable seq rejects null":
    expect nim_fastjson.JsonError:
      discard directDeserialize("null", seq[int])

  test "object string field rejects null":
    expect nim_fastjson.JsonError:
      discard directDeserialize("""{"a":1,"b":2.0,"c":null}""", Simple)

  test "object seq field rejects null":
    expect nim_fastjson.JsonError:
      discard directDeserialize("""{"items":null}""", WithSeq)

  test "Option string still accepts null":
    check directDeserialize("null", Option[string]).isNone

  test "Option seq still accepts null":
    check directDeserialize("null", Option[seq[int]]).isNone

  test "ref object still accepts null":
    check directDeserialize("null", RefObj) == nil

suite "RFC 8259 §4 – reject null as object key":
  test "null key in object is rejected via skipJsonValue":
    var i = 0
    let payload = """{null: "value"}"""
    expect nim_fastjson.JsonError:
      skipJsonValue(payload, i)

  test "null key in Table parse is rejected":
    expect nim_fastjson.JsonError:
      discard directDeserialize("""{null: "value"}""", Table[string, string])

  test "null key in typed object parse is rejected":
    expect nim_fastjson.JsonError:
      discard directDeserialize("""{null: 42}""", Simple)

  test "string key is accepted":
    let v = directDeserialize("""{"a": 1}""", Simple)
    check v.a == 1

  test "empty string key is accepted":
    let t = directDeserialize("""{"": "val"}""", Table[string, string])
    check t[""] == "val"

suite "direct engine enum table key errors":
  test "invalid enum key in Table raises JsonError":
    expect nim_fastjson.JsonError:
      discard directDeserialize("""{"missing": 1}""", Table[Status, int])

  test "invalid enum key in OrderedTable raises JsonError":
    expect nim_fastjson.JsonError:
      discard directDeserialize("""{"missing": 1}""", OrderedTable[Status, int])
