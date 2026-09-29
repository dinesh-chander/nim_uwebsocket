## Comprehensive test suite for nim_fastjson.
## Covers: primitives, strings (escaping, unicode, edge cases), numbers,
## objects (flat, nested, ref, empty, unknown fields), arrays (seq, fixed),
## Options, enums, Tables, whitespace tolerance, empty inputs, and
## roundtrip parity with jsony.

import std/[unittest, options, tables, strutils]
import jsony
import ../../nim_fastjson

let fastJson = initFastJson()

template serialize(value: untyped): untyped =
  fastJson.serialize(value)

template deserialize(json: untyped, T: typedesc): untyped =
  fastJson.deserialize(json, T)

template serializeInto(buf: untyped, value: untyped): untyped =
  fastJson.serializeInto(buf, value)

# ──────── helper types ────────

type
  Simple = object
    a: int
    b: float64
    c: string

  Nested = object
    name: string
    inner: Simple

  DeepNest = object
    level: int
    child: Nested

  WithOption = object
    id: int
    tag: Option[string]
    count: Option[int]

  Color = enum
    cRed, cBlue, cGreen

  WithEnum = object
    name: string
    color: Color

  RefObj = ref object
    id: int
    label: string

  WithRef = object
    name: string
    detail: RefObj

  AllInts = object
    a: int8
    b: int16
    c: int32
    d: int64
    e: uint8
    f: uint16
    g: uint32
    h: uint64

  AllFloats = object
    a: float32
    b: float64

  WithSeqs = object
    ints: seq[int]
    strs: seq[string]
    nested: seq[Simple]

  EmptyObj = object

  WithBool = object
    yes: bool
    no: bool

  WithTable = object
    data: Table[string, int]

  ManyStrings = object
    a: string
    b: string
    c: string
    d: string
    e: string
    f: string

# ──────── roundtrip helper ────────

proc roundtrip[T](value: T): bool =
  let json = serialize(value)
  let back = deserialize(json, T)
  serialize(back) == json

proc matchesJsony[T](value: T): bool =
  serialize(value) == jsony.toJson(value)

# ──────── tests ────────

suite "primitives":
  test "bool serialize":
    check serialize(true) == "true"
    check serialize(false) == "false"

  test "bool deserialize":
    check deserialize("true", bool) == true
    check deserialize("false", bool) == false

  test "int types serialize":
    check serialize(0) == "0"
    check serialize(42) == "42"
    check serialize(-1) == "-1"
    check serialize(int8(127)) == "127"
    check serialize(int8(-128)) == "-128"
    check serialize(uint64(18446744073709551615'u64)) == "18446744073709551615"

  test "int types deserialize":
    check deserialize("0", int) == 0
    check deserialize("42", int) == 42
    check deserialize("-1", int) == -1
    check deserialize("127", int8) == 127'i8
    check deserialize("255", uint8) == 255'u8

  test "float serialize":
    check serialize(0.0) == "0.0"
    check serialize(1.5) == "1.5"
    check serialize(-3.14) == jsony.toJson(-3.14)

  test "float deserialize":
    check deserialize("0.0", float64) == 0.0
    check deserialize("1.5", float64) == 1.5
    check deserialize("-3.14", float64) == -3.14
    check deserialize("1.34E3", float64) == 1.34E3
    check deserialize("9e-8", float64) == 9e-8

  test "all int types roundtrip":
    let v = AllInts(a: -50, b: 1000, c: -100000, d: 9999999999'i64,
                    e: 200, f: 50000, g: 3000000000'u32, h: 18000000000000000000'u64)
    check roundtrip(v)
    check matchesJsony(v)

  test "all float types roundtrip":
    let v = AllFloats(a: 1.5'f32, b: 3.14159265358979)
    check roundtrip(v)

suite "strings":
  test "simple string":
    check serialize("hello") == "\"hello\""
    check deserialize("\"hello\"", string) == "hello"

  test "empty string":
    check serialize("") == "\"\""
    check deserialize("\"\"", string) == ""

  test "escape characters":
    let s = "line\n\"quoted\"\ttab\\back"
    let encoded = serialize(s)
    check deserialize(encoded, string) == s

  test "all escape types roundtrip":
    let s = "special: \"\\/\b\f\n\r\t chars"
    check deserialize(serialize(s), string) == s

  test "unicode characters":
    let s = "hello 世界 🔒 café"
    let encoded = serialize(s)
    check deserialize(encoded, string) == s

  test "unicode escape sequences in input":
    # \u0020 is space
    let parsed = deserialize("\"hello\\u0020world\"", string)
    check parsed == "hello world"

  test "surrogate pair":
    # 🔒 = U+1F512 = \uD83D\uDD12
    let parsed = deserialize("\"\\uD83D\\uDD12\"", string)
    check parsed == "🔒"

  test "serialize matches jsony for tricky strings":
    check matchesJsony("hello\nworld")
    check matchesJsony("tab\there")
    check matchesJsony("quote\"inside")
    check matchesJsony("backslash\\here")
    check matchesJsony("как дела")  # cyrillic

  test "long string roundtrip":
    var long = ""
    for i in 0..<1000:
      long.add("abcdefghij")
    check deserialize(serialize(long), string) == long

  test "string with only special chars":
    let s = "\"\\\n\r\t"
    check deserialize(serialize(s), string) == s

  test "many strings object":
    let v = ManyStrings(a: "one", b: "two\n", c: "\"three\"", d: "",
                        e: "café", f: "a" & "\x00" & "b")
    check roundtrip(v)

suite "objects":
  test "flat object serialize":
    let v = Simple(a: 1, b: 2.5, c: "hi")
    check serialize(v) == """{"a":1,"b":2.5,"c":"hi"}"""
    check matchesJsony(v)

  test "flat object deserialize":
    let v = deserialize("""{"a":1,"b":2.5,"c":"hi"}""", Simple)
    check v.a == 1
    check v.b == 2.5
    check v.c == "hi"

  test "nested object roundtrip":
    let v = Nested(name: "outer", inner: Simple(a: 10, b: 0.0, c: "deep"))
    check roundtrip(v)
    check matchesJsony(v)

  test "deep nested roundtrip":
    let v = DeepNest(level: 1, child: Nested(
      name: "mid", inner: Simple(a: -5, b: 99.99, c: "leaf")))
    check roundtrip(v)
    check matchesJsony(v)

  test "empty object":
    let v = EmptyObj()
    check serialize(v) == "{}"
    discard deserialize("{}", EmptyObj)

  test "deserialize empty json object into populated type":
    let v = deserialize("{}", Simple)
    check v.a == 0
    check v.b == 0.0
    check v.c == ""

  test "skip unknown fields in object":
    let json = """{"a":1,"UNKNOWN":{"nested":[1,2]},"b":2.5,"c":"hi","extra":true}"""
    let v = deserialize(json, Simple)
    check v.a == 1
    check v.b == 2.5
    check v.c == "hi"

  test "fields out of order":
    let json = """{"c":"hello","a":42,"b":3.14}"""
    let v = deserialize(json, Simple)
    check v.a == 42
    check v.b == 3.14
    check v.c == "hello"

  test "bool fields":
    let v = WithBool(yes: true, no: false)
    check serialize(v) == """{"yes":true,"no":false}"""
    check roundtrip(v)
    check matchesJsony(v)

  test "ref object serialize":
    let v = WithRef(name: "test", detail: RefObj(id: 1, label: "ok"))
    check roundtrip(v)
    check matchesJsony(v)

  test "ref object nil serialize":
    let v = WithRef(name: "test", detail: nil)
    let json = serialize(v)
    check json.contains("null")
    check matchesJsony(v)

suite "sequences and arrays":
  test "seq[int]":
    check serialize(@[1, 2, 3]) == "[1,2,3]"
    check deserialize("[1,2,3]", seq[int]) == @[1, 2, 3]

  test "seq[string]":
    check serialize(@["a", "b"]) == """["a","b"]"""
    check deserialize("""["a","b"]""", seq[string]) == @["a", "b"]

  test "seq[float]":
    let v = @[1.5, 2.25, 3.0]
    check roundtrip(v)

  test "empty seq":
    check serialize(newSeq[int]()) == "[]"
    check deserialize("[]", seq[int]).len == 0

  test "nested seq":
    let v = @[@[1, 2], @[3, 4], newSeq[int]()]
    check roundtrip(v)

  test "seq[object]":
    let v = @[Simple(a: 1, b: 1.0, c: "x"), Simple(a: 2, b: 2.0, c: "y")]
    check roundtrip(v)
    check matchesJsony(v)

  test "object with seqs":
    let v = WithSeqs(
      ints: @[1, 2, 3],
      strs: @["hello", "world"],
      nested: @[Simple(a: 1, b: 0.0, c: "")]
    )
    check roundtrip(v)
    check matchesJsony(v)

  test "large seq roundtrip":
    var items: seq[Simple]
    for i in 0..<500:
      items.add(Simple(a: i, b: float64(i) * 0.1, c: "item" & $i))
    check roundtrip(items)

suite "options":
  test "Option[int] some":
    let v = WithOption(id: 1, tag: some("hello"), count: some(42))
    check roundtrip(v)

  test "Option[int] none":
    let v = WithOption(id: 2, tag: none(string), count: none(int))
    let json = serialize(v)
    check json.contains("null")
    check roundtrip(v)

  test "deserialize missing optional field":
    let v = deserialize("""{"id":3}""", WithOption)
    check v.id == 3
    check v.tag.isNone
    check v.count.isNone

  test "deserialize explicit null":
    let v = deserialize("""{"id":4,"tag":null,"count":null}""", WithOption)
    check v.tag.isNone
    check v.count.isNone

suite "enums":
  test "enum serialize":
    check serialize(cRed) == "\"cRed\""
    check serialize(cBlue) == "\"cBlue\""

  test "enum in object roundtrip":
    let v = WithEnum(name: "test", color: cGreen)
    check roundtrip(v)

  test "enum deserialize from string":
    check deserialize("\"cRed\"", Color) == cRed
    check deserialize("\"cBlue\"", Color) == cBlue

suite "tables":
  test "Table[string, int] serialize":
    var t: Table[string, int]
    t["a"] = 1
    t["b"] = 2
    let json = serialize(t)
    let back = deserialize(json, Table[string, int])
    check back["a"] == 1
    check back["b"] == 2

  test "empty table":
    var t: Table[string, int]
    check serialize(t) == "{}"
    check deserialize("{}", Table[string, int]).len == 0

  test "table in object":
    let v = WithTable(data: {"x": 10, "y": 20}.toTable)
    let json = serialize(v)
    let back = deserialize(json, WithTable)
    check back.data["x"] == 10
    check back.data["y"] == 20

suite "whitespace tolerance":
  test "leading/trailing whitespace":
    check deserialize("  42  ", int) == 42
    check deserialize("  \"hello\"  ", string) == "hello"
    check deserialize("  true  ", bool) == true

  test "whitespace in objects":
    let json = """  {  "a" :  1 ,  "b" : 2.5 , "c" : "hi"  }  """
    let v = deserialize(json, Simple)
    check v.a == 1
    check v.b == 2.5
    check v.c == "hi"

  test "whitespace in arrays":
    check deserialize("  [ 1 , 2 , 3 ]  ", seq[int]) == @[1, 2, 3]

  test "newlines and tabs":
    let json = "{\n\t\"a\": 1,\n\t\"b\": 2.5,\n\t\"c\": \"hi\"\n}"
    let v = deserialize(json, Simple)
    check v.a == 1

suite "error handling":
  test "invalid json raises JsonError":
    expect nim_fastjson.JsonError:
      discard deserialize("{invalid", Simple)

  test "truncated json":
    expect nim_fastjson.JsonError:
      discard deserialize("""{"a":1,"b":""", Simple)

  test "invalid number":
    expect nim_fastjson.JsonError:
      discard deserialize("{\"a\":abc}", Simple)

suite "edge cases":
  test "deeply nested skip":
    # Unknown field with deeply nested value
    let json = """{"a":1,"deep":{"x":{"y":{"z":[1,[2,[3]]]}}},"b":2.5,"c":"ok"}"""
    let v = deserialize(json, Simple)
    check v.a == 1
    check v.c == "ok"

  test "negative zero float":
    let v = deserialize("-0.0", float64)
    check v == 0.0

  test "very large int":
    check deserialize("9223372036854775807", int64) == high(int64)

  test "zero-length seq in object":
    let v = WithSeqs(ints: @[], strs: @[], nested: @[])
    check roundtrip(v)

  test "single element seq":
    check serialize(@[42]) == "[42]"
    check deserialize("[42]", seq[int]) == @[42]

  test "object with all defaults":
    let v = Simple()
    check roundtrip(v)
    check matchesJsony(v)

  test "serialize matches jsony across all test types":
    # Comprehensive jsony parity check
    check matchesJsony(Simple(a: -99, b: 1e-10, c: "test\n\"value\""))
    check matchesJsony(@[1, 2, 3])
    check matchesJsony(@["a", "b\nc"])
    check matchesJsony(true)
    check matchesJsony(42)
    check matchesJsony(3.14)
    check matchesJsony("hello world")
    check matchesJsony(WithBool(yes: true, no: false))
    check matchesJsony(Nested(name: "x", inner: Simple(a: 0, b: 0.0, c: "")))

suite "jsonSafe pragma":
  test "safe strings skip escape scanning":
    type SafeObj = object
      id: int
      name {.jsonSafe.}: string
      tag {.jsonSafe.}: string
    let v = SafeObj(id: 1, name: "hello", tag: "world")
    check serialize(v) == """{"id":1,"name":"hello","tag":"world"}"""
    check roundtrip(v)

  test "safe string with normal strings mixed":
    type MixedObj = object
      safe {.jsonSafe.}: string
      unsafe: string
    let v = MixedObj(safe: "clean", unsafe: "has\"quote")
    check roundtrip(v)

suite "borrowed strings (simd backend)":
  type
    BorrowedTodo = object
      id: int
      title: JsonStringView
      completed: bool

    BorrowedEnvelope = object
      todos: seq[BorrowedTodo]
      nextCursor: JsonStringView

  test "borrowed types use simd engine":
    check selectedDeserializeEngine(BorrowedEnvelope) == fjeSimdjson

  test "borrowed string deserialize":
    let json = """{"todos":[{"id":1,"title":"a","completed":false}],"nextCursor":"p1"}"""
    let v = deserialize(json, BorrowedEnvelope)
    check v.todos.len == 1
    check v.todos[0].id == 1
    check v.todos[0].title.toString() == "a"
    check v.nextCursor.toString() == "p1"

  test "borrowed roundtrip via serialize":
    let json = """{"todos":[{"id":1,"title":"a","completed":false},{"id":2,"title":"b","completed":true}],"nextCursor":"p2"}"""
    let v = deserialize(json, BorrowedEnvelope)
    check serialize(v) == json

suite "serializeInto (zero-alloc)":
  test "reuse buffer":
    var buf = newStringOfCap(256)
    let v1 = Simple(a: 1, b: 2.0, c: "hi")
    serializeInto(buf, v1)
    check buf == """{"a":1,"b":2.0,"c":"hi"}"""
    let v2 = Simple(a: 99, b: 0.0, c: "")
    serializeInto(buf, v2)
    check buf == """{"a":99,"b":0.0,"c":""}"""

  test "buffer grows as needed":
    var buf = ""
    var items: seq[Simple]
    for i in 0..<100:
      items.add(Simple(a: i, b: 0.0, c: "x"))
    serializeInto(buf, items)
    let back = deserialize(buf, seq[Simple])
    check back.len == 100
    check back[50].a == 50
